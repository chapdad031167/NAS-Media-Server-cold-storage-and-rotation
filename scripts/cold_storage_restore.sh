#!/bin/bash
# ============================================================
# cold_storage_restore.sh v1
# The way back: moves an archived item from cold storage to the
# hot pool with the same rsync copy -> checksum verify -> delete
# pattern the cycle script uses, then re-monitors it in
# Radarr/Sonarr (id looked up from the archive manifest).
#
# Usage:
#   bash cold_storage_restore.sh                      <- list archived items
#   bash cold_storage_restore.sh "<name>"             <- dry-run restore (default)
#   bash cold_storage_restore.sh "<name>" --run       <- live restore + re-monitor
#
# <name> is a case-insensitive substring matched against the
# folder names in $COLD_ROOT/Movies and $COLD_ROOT/TV Shows.
# Exactly one item must match; ambiguous matches are listed so
# you can narrow the query.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090  # user-supplied config, path known only at runtime
    source "$CONFIG_FILE"
fi

COLD_ROOT="${COLD_ROOT:?Set COLD_ROOT in config.env (cold storage mount point)}"
COLD_MOVIES="$COLD_ROOT/Movies"
COLD_TV="$COLD_ROOT/TV Shows"
MOVIES_DIR="${MOVIES_DIR:-/volume1/Movies}"
TV_DIR="${TV_DIR:-/volume1/TV Shows}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/../logs}"
LOG_FILE="$LOG_DIR/cold_storage_restore_$(date +%Y%m%d_%H%M%S).log"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-90}"
LOCK_DIR="${LOCK_DIR:-${TMPDIR:-/tmp}}"
MANIFEST_FILE="${MANIFEST_FILE:-$COLD_ROOT/cold_storage_manifest.jsonl}"
NTFY_URL="${NTFY_URL:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

RADARR_URL="${RADARR_URL:-http://localhost:7878}"
RADARR_API_KEY="${RADARR_API_KEY:-}"
SONARR_URL="${SONARR_URL:-http://localhost:8989}"
SONARR_API_KEY="${SONARR_API_KEY:-}"

QUERY="${1:-}"
DRY_RUN=true
if [[ "$2" == "--run" ]]; then
    DRY_RUN=false
fi

# Refuse to run concurrently with another restore OR with the
# cycle script - both walk the same trees.
exec 9>"$LOCK_DIR/nas_media_cold_storage_cycle.lock"
if ! flock -n 9; then
    echo "ERROR: a cold storage cycle/restore is already running. Exiting." >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
find "$LOG_DIR" -maxdepth 1 -name '*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

notify() {
    local msg="$1"
    if [[ -n "$NTFY_URL" ]]; then
        curl -fsS -m 10 -H "Title: cold_storage_restore" -d "$msg" "$NTFY_URL" >/dev/null 2>&1 \
            || log "WARNING: ntfy notification failed"
    fi
    if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
        curl -fsS -m 10 -H "Content-Type: application/json" \
            -d "$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$msg")" \
            "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 \
            || log "WARNING: discord notification failed"
    fi
}

# append_manifest EVENT TYPE ID NAME SRC DEST BYTES
append_manifest() {
    python3 - "$MANIFEST_FILE" "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PYEOF'
import datetime, json, sys
entry = {
    "event": sys.argv[2],
    "at": datetime.datetime.now().isoformat(timespec="seconds"),
    "type": sys.argv[3],
    "id": sys.argv[4],
    "name": sys.argv[5],
    "src": sys.argv[6],
    "dest": sys.argv[7],
    "size_bytes": int(sys.argv[8] or 0),
}
with open(sys.argv[1], "a") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF
}

# --- COLD STORAGE MOUNT CHECK (v1) ---------------------------
# The archive we read from must be mounted; fail clearly if not,
# rather than reporting an empty (misleading) archive listing.
COLD_PARENT="$(dirname "$COLD_ROOT")"
if [[ ! -d "$COLD_PARENT" ]]; then
    log "ERROR: Cold storage mount not found: $COLD_PARENT"
    log "COLD_ROOT is set to '$COLD_ROOT' but its parent directory does not exist."
    log "Check COLD_ROOT in your config.env, or plug in the archive drive and"
    log "find its real mount with:  df -h | grep -i usb"
    exit 1
fi

# --- LIST MODE -----------------------------------------------
if [[ -z "$QUERY" ]]; then
    log "Archived items in $COLD_ROOT:"
    log ""
    FOUND_ANY=false
    for DIR in "$COLD_MOVIES" "$COLD_TV"; do
        [[ -d "$DIR" ]] || continue
        while IFS= read -r -d $'\0' item; do
            FOUND_ANY=true
            SIZE=$(du -sh "$item" 2>/dev/null | cut -f1)
            log "  [$(basename "$DIR")] $(basename "$item") ($SIZE)"
        done < <(find "$DIR" -maxdepth 1 -mindepth 1 -print0 | sort -z)
    done
    if [[ "$FOUND_ANY" == false ]]; then
        log "  (nothing archived yet)"
    fi
    log ""
    log "Restore with: bash cold_storage_restore.sh \"<name>\" [--run]"
    exit 0
fi

if ! command -v rsync >/dev/null 2>&1; then
    log "ERROR: rsync not found."
    exit 1
fi

# --- MATCH ---------------------------------------------------
QUERY_LOWER="${QUERY,,}"
MATCHES=()
for DIR in "$COLD_MOVIES" "$COLD_TV"; do
    [[ -d "$DIR" ]] || continue
    while IFS= read -r -d $'\0' item; do
        NAME_LOWER="$(basename "$item")"
        NAME_LOWER="${NAME_LOWER,,}"
        if [[ "$NAME_LOWER" == *"$QUERY_LOWER"* ]]; then
            MATCHES+=("$item")
        fi
    done < <(find "$DIR" -maxdepth 1 -mindepth 1 -print0 | sort -z)
done

if [[ ${#MATCHES[@]} -eq 0 ]]; then
    log "ERROR: nothing in cold storage matches \"$QUERY\"."
    log "Run without arguments to list archived items."
    exit 1
fi
if [[ ${#MATCHES[@]} -gt 1 ]]; then
    log "ERROR: \"$QUERY\" matches ${#MATCHES[@]} archived items - narrow the query:"
    for m in "${MATCHES[@]}"; do
        log "  $(basename "$m")"
    done
    exit 1
fi

SRC_PATH="${MATCHES[0]}"
BASENAME=$(basename "$SRC_PATH")

if [[ "$SRC_PATH" == "$COLD_MOVIES/"* ]]; then
    ITEM_TYPE="movie"
    DEST_ROOT="$MOVIES_DIR"
else
    ITEM_TYPE="tv"
    DEST_ROOT="$TV_DIR"
fi
DEST_PATH="$DEST_ROOT/$BASENAME"

# Manifest lookup: recover the Radarr/Sonarr id recorded when
# the item was archived, so we can re-monitor it.
MANIFEST_META=$(python3 - "$MANIFEST_FILE" "$SRC_PATH" <<'PYEOF'
import json, sys
target, best = sys.argv[2], None
try:
    with open(sys.argv[1]) as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("event") == "archived" and e.get("dest") == target:
                best = e  # last archived entry for this dest wins
except OSError:
    pass
if best:
    updated = "true" if best.get("arr_path_updated") else "false"
    print(f"{best.get('type', '')}\t{best.get('id', '')}\t{updated}")
PYEOF
)
ITEM_ID=""
ARR_PATH_UPDATED=false
if [[ -n "$MANIFEST_META" ]]; then
    IFS=$'\t' read -r MANIFEST_TYPE ITEM_ID ARR_PATH_UPDATED <<<"$MANIFEST_META"
    [[ -n "$MANIFEST_TYPE" ]] && ITEM_TYPE="$MANIFEST_TYPE"
    ARR_PATH_UPDATED="${ARR_PATH_UPDATED:-false}"
fi

log "=============================="
log "  cold_storage_restore.sh v1"
log "  DRY_RUN: $DRY_RUN"
log "  Item:  $BASENAME ($ITEM_TYPE)"
log "  FROM:  $SRC_PATH"
log "  TO:    $DEST_PATH"
if [[ -n "$ITEM_ID" ]]; then
    log "  Re-monitor: yes ($ITEM_TYPE id $ITEM_ID from manifest)"
else
    log "  Re-monitor: no (item not found in manifest $MANIFEST_FILE)"
fi
log "=============================="
log ""

# Free space preflight on the hot pool
NEEDED=$(du -sb "$SRC_PATH" 2>/dev/null | cut -f1)
NEEDED=${NEEDED:-0}
HOT_AVAIL=$(df -PB1 "$DEST_ROOT" 2>/dev/null | awk 'NR==2{print $4}')
HOT_AVAIL=${HOT_AVAIL:-0}
if (( HOT_AVAIL < NEEDED + NEEDED / 20 )); then
    log "ERROR: not enough free space on the hot pool for $BASENAME. Aborting."
    notify "cold_storage_restore ERROR: not enough hot pool space for $BASENAME"
    exit 1
fi

# set_monitored ID MONITORED [NEW_PATH] -> flips the monitored
# flag in Radarr/Sonarr (same API pattern as the cycle script's
# unmonitor). With NEW_PATH the item is also repointed at its
# restored hot-pool location (moveFiles=false - we already moved
# the files), reversing an UPDATE_ARR_PATHS=true archive.
set_monitored() {
    local ITEM_ID="$1"
    local MONITORED="$2"
    local NEW_PATH="${3:-}"

    local BASE KEY ENDPOINT
    if [[ "$ITEM_TYPE" == "movie" ]]; then
        BASE="$RADARR_URL"; KEY="$RADARR_API_KEY"; ENDPOINT="movie"
    else
        BASE="$SONARR_URL"; KEY="$SONARR_API_KEY"; ENDPOINT="series"
    fi

    if [[ -z "$KEY" ]]; then
        log "             RE-MONITOR: skipped (no API key configured - see config.env.example)"
        return 1
    fi

    python3 - "$BASE" "$KEY" "$ENDPOINT" "$ITEM_ID" "$MONITORED" "$NEW_PATH" <<'PYEOF'
import sys, json, urllib.request
base, key, endpoint, item_id, monitored, new_path = sys.argv[1:7]
url = f"{base}/api/v3/{endpoint}/{item_id}"
headers = {"X-Api-Key": key, "Content-Type": "application/json"}
try:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        obj = json.loads(r.read().decode())
    obj["monitored"] = monitored == "true"
    if new_path:
        obj["path"] = new_path
    data = json.dumps(obj).encode()
    req = urllib.request.Request(
        url + "?moveFiles=false", data=data, headers=headers, method="PUT"
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        r.read()
    sys.exit(0)
except Exception as e:
    print(f"set_monitored failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# move_verified SRC DEST -> 0 on verified move, 1 on failure
# (same contract as cold_storage_cycle.sh)
move_verified() {
    local SRC="$1"
    local DEST="$2"

    if [[ -d "$SRC" ]]; then
        if ! rsync -a "$SRC/" "$DEST/" < /dev/null; then
            return 1
        fi
        local DIFF
        DIFF=$(rsync -rcn --out-format='%n' "$SRC/" "$DEST/" < /dev/null)
        if [[ -n "$DIFF" ]]; then
            log "             VERIFY FAILED - differing files:"
            log "             $DIFF"
            return 1
        fi
        rm -rf -- "$SRC"
    else
        if ! rsync -a "$SRC" "$DEST" < /dev/null; then
            return 1
        fi
        local DIFF
        DIFF=$(rsync -cn --out-format='%n' "$SRC" "$DEST" < /dev/null)
        if [[ -n "$DIFF" ]]; then
            log "             VERIFY FAILED - checksum mismatch"
            return 1
        fi
        rm -f -- "$SRC"
    fi
    return 0
}

if [[ "$DRY_RUN" == true ]]; then
    log "STATUS: [DRY RUN] - no action taken"
    log "Run with: bash cold_storage_restore.sh \"$QUERY\" --run"
    exit 0
fi

SIZE_BYTES=$NEEDED
if move_verified "$SRC_PATH" "$DEST_PATH"; then
    log "STATUS: Restored + checksum verified OK"
    append_manifest "restored" "$ITEM_TYPE" "$ITEM_ID" "$BASENAME" "$SRC_PATH" "$DEST_PATH" "$SIZE_BYTES" \
        || log "MANIFEST: WARNING - could not write $MANIFEST_FILE"
    if [[ -n "$ITEM_ID" ]]; then
        # If the archive updated the item's path in Radarr/Sonarr,
        # point it back at the hot pool as we re-monitor.
        REMONITOR_PATH=""
        if [[ "$ARR_PATH_UPDATED" == true ]]; then
            REMONITOR_PATH="$DEST_PATH"
        fi
        if set_monitored "$ITEM_ID" "true" "$REMONITOR_PATH"; then
            log "RE-MONITOR: OK ($ITEM_TYPE id $ITEM_ID)"
            log "Radarr/Sonarr will pick the files up on their next library refresh."
        fi
    else
        log "RE-MONITOR: skipped (no id available - re-enable monitoring manually)"
    fi
    notify "cold_storage_restore: restored $BASENAME to the hot pool"
else
    log "STATUS: ERROR - restore/verify failed, ARCHIVE COPY KEPT"
    notify "cold_storage_restore ERROR: restore of $BASENAME failed, archive copy kept"
    exit 1
fi

log ""
log "Log saved to: $LOG_FILE"
