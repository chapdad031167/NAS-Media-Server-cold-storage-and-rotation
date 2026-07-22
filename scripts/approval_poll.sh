#!/bin/bash
# ============================================================
# approval_poll.sh v1.0
# The execution half of one-tap archive approval.
#
# Flow: cold_storage_scan.py (with REMOTE_APPROVE=true) pushes
# its report to NTFY_URL with an "Approve archive" button.
# Tapping the button publishes APPROVE_TOKEN to the private
# APPROVE_URL topic. This script - run from cron every few
# minutes - polls that topic and, when a message carrying the
# exact token appears, executes:
#     cold_storage_cycle.sh --run
#
# Safety model:
#   - Disarmed by default: does nothing unless REMOTE_APPROVE
#     is exactly "true" AND both APPROVE_URL and APPROVE_TOKEN
#     are configured.
#   - APPROVE_TOKEN is a shared secret and both topic URLs are
#     credentials (anyone holding them can read reports or
#     attempt approvals) - treat them like API keys. They reach
#     curl via --config on stdin, never argv.
#   - Non-matching messages are logged and ignored; the state
#     file advances past them so nothing is ever retried.
#   - Replay-proof: each poll resumes from the last message id
#     seen. A first run (no state) only looks APPROVE_LOOKBACK
#     (default 30m) into the past, so an ancient approval can't
#     fire a fresh install.
#   - At most ONE cycle run per poll, and every guard inside
#     cold_storage_cycle.sh still applies to the triggered run:
#     candidate staleness, per-item size re-verify, free-space
#     preflight, checksum-verified moves.
#
# Usage:
#   bash approval_poll.sh        <- poll once (cron this)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    # config.env is sourced (executed) - refuse it if group- or
    # other-writable, which would let another user inject code here.
    _cfg_perm=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$_cfg_perm" && $(( 8#$_cfg_perm & 022 )) -ne 0 ]]; then
        echo "ERROR: $CONFIG_FILE is group/other-writable (mode $_cfg_perm); refusing to source it." >&2
        echo "Fix with: chmod 600 $CONFIG_FILE" >&2
        exit 1
    fi
    # shellcheck disable=SC1090  # user-supplied config, path known only at runtime
    source "$CONFIG_FILE"
fi

REMOTE_APPROVE="${REMOTE_APPROVE:-false}"
APPROVE_URL="${APPROVE_URL:-}"
APPROVE_TOKEN="${APPROVE_TOKEN:-}"
APPROVE_LOOKBACK="${APPROVE_LOOKBACK:-30m}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/../logs}"
LOG_FILE="$LOG_DIR/approval_poll_$(date +%Y%m%d).log"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-90}"
# Locks default to a user-owned dir inside the install, not /tmp:
# predictable names in world-writable /tmp invite lock-squatting.
LOCK_DIR="${LOCK_DIR:-$SCRIPT_DIR/../.locks}"
# Last ntfy message id we've already seen (user-owned dir, same
# reasoning as the locks).
STATE_FILE="${STATE_FILE:-$LOCK_DIR/approval_poll.since}"

# Disarmed is the default and perfectly healthy - exit quietly so
# a cron'd poller on a non-approving install stays silent.
if [[ "$REMOTE_APPROVE" != "true" ]]; then
    exit 0
fi

if [[ -z "$APPROVE_URL" || -z "$APPROVE_TOKEN" ]]; then
    echo "ERROR: REMOTE_APPROVE=true but APPROVE_URL/APPROVE_TOKEN not set in config.env" >&2
    exit 1
fi

# One poller at a time (fd 9 holds the lock for the lifetime of
# the script; a triggered cycle can run for hours).
mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/nas_media_approval_poll.lock"
if ! flock -n 9; then
    # Normal when a triggered cycle is still moving data.
    exit 0
fi

mkdir -p "$LOG_DIR"
find "$LOG_DIR" -maxdepth 1 -name '*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Best-effort push notification (ntfy and/or Discord webhook) -
# same pattern as the other scripts: the webhook URL is itself a
# credential, so it reaches curl via --config on stdin, never argv.
NTFY_URL="${NTFY_URL:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
notify() {
    local msg="$1"
    if [[ -n "$NTFY_URL" ]]; then
        printf 'url = "%s"\n' "$NTFY_URL" \
            | curl -fsS -m 10 -H "Title: approval_poll" -d "$msg" -K - >/dev/null 2>&1 \
            || log "WARNING: ntfy notification failed"
    fi
    if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
        printf 'url = "%s"\n' "$DISCORD_WEBHOOK_URL" \
            | curl -fsS -m 10 -H "Content-Type: application/json" \
                -d "$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$msg")" \
                -K - >/dev/null 2>&1 \
            || log "WARNING: discord notification failed"
    fi
}

# --- Poll the approval topic ---------------------------------
SINCE=$(cat "$STATE_FILE" 2>/dev/null || true)
[[ -z "$SINCE" ]] && SINCE="$APPROVE_LOOKBACK"

RESPONSE_FILE=$(mktemp "$LOCK_DIR/approval_poll_response.XXXXXX")
trap 'rm -f "$RESPONSE_FILE"' EXIT

# The topic URL is a credential: pass it via --config on stdin.
if ! printf 'url = "%s/json?poll=1&since=%s"\n' "$APPROVE_URL" "$SINCE" \
        | curl -fsS -m 15 -K - > "$RESPONSE_FILE" 2>/dev/null; then
    log "WARNING: could not poll approval topic (network/ntfy down?) - will retry next cron run"
    exit 0
fi

# Parse the JSON-lines poll response. The token is compared in
# python and passed via env, keeping it off argv.
RESULT=$(NAS_APPROVE_TOKEN="$APPROVE_TOKEN" python3 - "$RESPONSE_FILE" <<'PYEOF'
import json, os, sys

token = os.environ.get("NAS_APPROVE_TOKEN", "")
last_id, matched, ignored = "", 0, 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("event") != "message":
            continue
        last_id = msg.get("id", "") or last_id
        if token and msg.get("message", "") == token:
            matched += 1
        else:
            ignored += 1
print(f"{last_id}\t{matched}\t{ignored}")
PYEOF
)

LAST_ID="$(cut -f1 <<< "$RESULT")"
MATCHED="$(cut -f2 <<< "$RESULT")"
IGNORED="$(cut -f3 <<< "$RESULT")"

# Advance the state past everything we just saw - valid or not -
# so no message (including a bad one) is ever processed twice.
if [[ -n "$LAST_ID" ]]; then
    printf '%s\n' "$LAST_ID" > "$STATE_FILE"
fi

if [[ "$IGNORED" -gt 0 ]]; then
    log "WARNING: ignored $IGNORED non-matching message(s) on the approval topic"
fi

if [[ "$MATCHED" -eq 0 ]]; then
    exit 0
fi

# --- Approved: run the archive cycle -------------------------
log "Approval received - starting cold_storage_cycle.sh --run"
notify "approval_poll: approval received - starting archive cycle"

if bash "$SCRIPT_DIR/cold_storage_cycle.sh" --run >> "$LOG_FILE" 2>&1; then
    log "Archive cycle finished (see cycle log/notification for the summary)"
else
    rc=$?
    log "ERROR: archive cycle exited with status $rc"
    notify "approval_poll ERROR: archive cycle exited with status $rc"
    exit "$rc"
fi
