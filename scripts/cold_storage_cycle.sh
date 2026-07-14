#!/bin/bash
# ============================================================
# cold_storage_cycle.sh v2.4
# Reads the candidate JSON produced by cold_storage_scan.py and
# moves each candidate to cold storage.
#   Movies -> $COLD_ROOT/Movies/
#   TV     -> $COLD_ROOT/TV Shows/
#
# Changes in v2.4:
#   - ARCHIVED MEDIA STAYS VISIBLE: with UPDATE_ARR_PATHS=true,
#     the item's path in Radarr/Sonarr is updated to its cold
#     storage location (moveFiles=false - we already moved it)
#     instead of being orphaned. Add $COLD_ROOT/Movies and
#     "$COLD_ROOT/TV Shows" as root folders in Radarr/Sonarr
#     first, and optionally as an "Archive" library in Plex, so
#     archived media stays browsable and playable. Items are
#     still unmonitored either way so nothing re-downloads.
#
# Changes in v2.3:
#   - ARCHIVE MANIFEST: every verified move appends a JSON line
#     to $MANIFEST_FILE (default: on the cold drive itself), so
#     "where's that movie?" is answerable without mounting the
#     drive, and cold_storage_restore.sh can re-monitor items.
#   - CAPACITY TARGET: with POOL_TARGET_PCT set (e.g. 80), moves
#     oldest-first and stops as soon as pool usage drops to the
#     target, instead of archiving everything eligible. 0 (the
#     default) keeps the old move-everything behaviour.
#   - NOTIFICATIONS: end-of-run summary and fatal errors pushed
#     to NTFY_URL and/or DISCORD_WEBHOOK_URL when configured.
#
# Changes in v2.2:
#   - STALENESS GUARD: refuses to --run from a candidate file
#     older than CANDIDATE_MAX_AGE_DAYS (default 7); dry runs
#     warn instead. The library changes; old scans lie.
#   - SIZE RE-VERIFY: an item whose on-disk size grew >20% since
#     the scan (quality upgrade?) is skipped - rerun the scan.
#   - flock lock file prevents overlapping runs.
#   - Old logs pruned after LOG_RETENTION_DAYS (default 90).
#
# Changes in v2.1:
#   - Secrets/paths moved to config.env / environment.
#   - Unmonitor is skipped with a warning when no API key is
#     configured, instead of failing the API call.
#
# Fixes in v2:
#   - VERIFIED MOVES: replaced bare `mv` (copy+delete across
#     filesystems) with rsync copy -> checksum verify -> delete
#     source. A bare mv interrupted mid-copy left a partial
#     destination that the old "-e DEST -> SKIP" check then
#     silently skipped forever. Partial destinations are now
#     RESUMED and verified instead of skipped.
#   - UNMONITOR: after a verified move, unmonitors the item in
#     Radarr/Sonarr via API (requires "id" in the candidate
#     JSON from cold_storage_scan.py v2.1+). Without this,
#     Radarr re-downloads archived monitored movies.
#   - FREE SPACE PREFLIGHT: aborts if the cold drive lacks
#     space for the full candidate set (+5% headroom).
#   - Guarded SIZE_BYTES against empty values.
#
# Usage:
#   bash cold_storage_cycle.sh          <- dry run (default)
#   bash cold_storage_cycle.sh --run    <- live move
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

CANDIDATE_FILE="${CANDIDATE_FILE:-$SCRIPT_DIR/../cold_storage_candidates.json}"
COLD_ROOT="${COLD_ROOT:?Set COLD_ROOT in config.env (cold storage mount point)}"
COLD_MOVIES="$COLD_ROOT/Movies"
COLD_TV="$COLD_ROOT/TV Shows"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/../logs}"
LOG_FILE="$LOG_DIR/cold_storage_cycle_$(date +%Y%m%d_%H%M%S).log"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-90}"
LOCK_DIR="${LOCK_DIR:-${TMPDIR:-/tmp}}"
CANDIDATE_MAX_AGE_DAYS="${CANDIDATE_MAX_AGE_DAYS:-7}"
MANIFEST_FILE="${MANIFEST_FILE:-$COLD_ROOT/cold_storage_manifest.jsonl}"
POOL_TARGET_PCT="${POOL_TARGET_PCT:-0}"
NTFY_URL="${NTFY_URL:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DRY_RUN=true

# Guard against a non-numeric capacity target
if ! [[ "$POOL_TARGET_PCT" =~ ^[0-9]+$ ]]; then
    echo "WARNING: POOL_TARGET_PCT must be an integer percentage; ignoring '$POOL_TARGET_PCT'" >&2
    POOL_TARGET_PCT=0
fi

# Unmonitor moved items in Radarr/Sonarr (recommended: true)
UNMONITOR="${UNMONITOR:-true}"
# Also update the item's Radarr/Sonarr path to the cold storage
# location so it stays visible (requires the cold folders to be
# configured as root folders in Radarr/Sonarr)
UPDATE_ARR_PATHS="${UPDATE_ARR_PATHS:-false}"
RADARR_URL="${RADARR_URL:-http://localhost:7878}"
RADARR_API_KEY="${RADARR_API_KEY:-}"
SONARR_URL="${SONARR_URL:-http://localhost:8989}"
SONARR_API_KEY="${SONARR_API_KEY:-}"

# Host library paths + container prefixes (for legacy candidate
# files that still contain container-style paths)
MOVIES_DIR="${MOVIES_DIR:-/volume1/Movies}"
TV_DIR="${TV_DIR:-/volume1/TV Shows}"
MOVIE_CONTAINER_PREFIX="${MOVIE_CONTAINER_PREFIX:-/movies/}"
TV_CONTAINER_PREFIX="${TV_CONTAINER_PREFIX:-/tv/}"

if [[ "$1" == "--run" ]]; then
    DRY_RUN=false
fi

# Refuse to run concurrently (fd 9 holds the lock for the
# lifetime of the script) - a cycle can run for hours and a
# second instance walking the same candidate list would collide.
exec 9>"$LOCK_DIR/nas_media_cold_storage_cycle.lock"
if ! flock -n 9; then
    echo "ERROR: another cold_storage_cycle.sh is already running. Exiting." >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
find "$LOG_DIR" -maxdepth 1 -name '*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Best-effort push notification (ntfy and/or Discord webhook).
# No-op when neither URL is configured; a failed push warns but
# never breaks the run.
notify() {
    local msg="$1"
    if [[ -n "$NTFY_URL" ]]; then
        curl -fsS -m 10 -H "Title: cold_storage_cycle" -d "$msg" "$NTFY_URL" >/dev/null 2>&1 \
            || log "WARNING: ntfy notification failed"
    fi
    if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
        curl -fsS -m 10 -H "Content-Type: application/json" \
            -d "$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$msg")" \
            "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 \
            || log "WARNING: discord notification failed"
    fi
}

# append_manifest EVENT TYPE ID NAME SRC DEST BYTES [ARR_PATH_UPDATED]
# One JSON line per event; the manifest lives on the cold drive
# so it travels with the archive.
append_manifest() {
    python3 - "$MANIFEST_FILE" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-false}" <<'PYEOF'
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
    "arr_path_updated": sys.argv[9] == "true",
}
with open(sys.argv[1], "a") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF
}

if [[ ! -f "$CANDIDATE_FILE" ]]; then
    log "ERROR: Candidate file not found: $CANDIDATE_FILE"
    log "Run cold_storage_scan.py first."
    notify "cold_storage_cycle ERROR: candidate file not found ($CANDIDATE_FILE)"
    exit 1
fi

# --- STALENESS GUARD (v2.2) ----------------------------------
# The candidate list is a snapshot; the library keeps changing
# underneath it (upgrades, deletions, new downloads). Refuse to
# execute from an old snapshot.
CAND_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$CANDIDATE_FILE") ) / 86400 ))
if (( CAND_AGE_DAYS > CANDIDATE_MAX_AGE_DAYS )); then
    if [[ "$DRY_RUN" == false ]]; then
        log "ERROR: Candidate file is $CAND_AGE_DAYS days old (max: $CANDIDATE_MAX_AGE_DAYS)."
        log "Rerun cold_storage_scan.py to get a fresh snapshot before --run."
        notify "cold_storage_cycle ERROR: refused --run, candidate file is $CAND_AGE_DAYS days old"
        exit 1
    else
        log "WARNING: Candidate file is $CAND_AGE_DAYS days old (max: $CANDIDATE_MAX_AGE_DAYS)."
        log "         This dry run may not reflect the current library. Rerun the scan."
    fi
fi

if ! command -v rsync >/dev/null 2>&1; then
    log "ERROR: rsync not found. Install rsync or fall back to v1 (not recommended)."
    exit 1
fi

# --- COLD STORAGE MOUNT CHECK (v2.4) -------------------------
# Fail early and clearly if COLD_ROOT's mount is missing, instead
# of letting a bad path fall through to a "0.00 GB free" abort or
# a "mkdir: Permission denied". COLD_ROOT itself may not exist yet
# on a first run (we create the /Cold subfolder), so we check its
# PARENT - the actual mount point - which must already be present.
COLD_PARENT="$(dirname "$COLD_ROOT")"
if [[ ! -d "$COLD_PARENT" ]]; then
    log "ERROR: Cold storage mount not found: $COLD_PARENT"
    log "COLD_ROOT is set to '$COLD_ROOT' but its parent directory does not exist."
    log "Check COLD_ROOT in your config.env, or plug in the archive drive and"
    log "find its real mount with:  df -h | grep -i usb"
    log "(On Synology it is usually /mnt/@usb/sdX1/... or /volumeUSB1/usbshare/...)"
    notify "cold_storage_cycle ERROR: cold storage mount not found ($COLD_PARENT)"
    exit 1
fi

log "=============================="
log "  cold_storage_cycle.sh v2.4"
log "  DRY_RUN: $DRY_RUN"
log "  UNMONITOR: $UNMONITOR"
log "  UPDATE_ARR_PATHS: $UPDATE_ARR_PATHS"
log "  Source file: $CANDIDATE_FILE"
log "  Dest (movies): $COLD_MOVIES"
log "  Dest (TV):     $COLD_TV"
log "=============================="
log ""

if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$COLD_MOVIES"
    mkdir -p "$COLD_TV"
fi

# --- FREE SPACE PREFLIGHT (v2) -------------------------------
if ! TOTAL_NEEDED=$(python3 -c "
import json
with open('$CANDIDATE_FILE') as f:
    data = json.load(f)
print(data.get('total_size_bytes', 0))
"); then
    log "ERROR: could not parse candidate file $CANDIDATE_FILE (invalid JSON?)."
    log "Rerun cold_storage_scan.py to regenerate it."
    notify "cold_storage_cycle ERROR: candidate file parse failed ($CANDIDATE_FILE)"
    exit 1
fi
COLD_AVAIL=$(df -PB1 "$COLD_ROOT" 2>/dev/null | awk 'NR==2{print $4}')
COLD_AVAIL=${COLD_AVAIL:-0}
NEEDED_WITH_HEADROOM=$(( TOTAL_NEEDED + TOTAL_NEEDED / 20 ))

log "Preflight: need $(awk "BEGIN {printf \"%.2f\", $TOTAL_NEEDED/1073741824}") GB (+5% headroom), cold drive has $(awk "BEGIN {printf \"%.2f\", $COLD_AVAIL/1073741824}") GB free"
if [[ "$COLD_AVAIL" -lt "$NEEDED_WITH_HEADROOM" ]]; then
    log "ERROR: Not enough free space on cold storage. Aborting."
    notify "cold_storage_cycle ERROR: not enough free space on cold storage"
    exit 1
fi
log ""

# --- CAPACITY TARGET (v2.3) ----------------------------------
# With POOL_TARGET_PCT > 0 we archive oldest-first and stop as
# soon as the hot pool is back at/below the target percentage.
POOL_TOTAL=0
POOL_USED=0
if (( POOL_TARGET_PCT > 0 )); then
    read -r POOL_TOTAL POOL_USED < <(df -PB1 "$MOVIES_DIR" 2>/dev/null | awk 'NR==2{print $2, $3}')
    POOL_TOTAL=${POOL_TOTAL:-0}
    POOL_USED=${POOL_USED:-0}
    if (( POOL_TOTAL > 0 )); then
        log "Pool usage: $(( POOL_USED * 100 / POOL_TOTAL ))% (capacity target: ${POOL_TARGET_PCT}%)"
        log ""
    else
        log "WARNING: could not measure pool usage of $MOVIES_DIR; capacity target ignored"
        POOL_TARGET_PCT=0
    fi
fi

# --- UNMONITOR / PATH-UPDATE HELPER (v2, v2.4) ----------------
# unmonitor_item TYPE ID [NEW_PATH]
# Sets monitored=false in Radarr/Sonarr; with NEW_PATH also
# repoints the item at its cold storage location (moveFiles=false
# because we already moved the files ourselves).
unmonitor_item() {
    local ITEM_TYPE="$1"
    local ITEM_ID="$2"
    local NEW_PATH="${3:-}"

    if [[ -z "$ITEM_ID" || "$ITEM_ID" == "None" || "$ITEM_ID" == "null" ]]; then
        log "             UNMONITOR: skipped (no id in candidate JSON - rerun scan v2.1+)"
        return 1
    fi

    local BASE KEY ENDPOINT
    if [[ "$ITEM_TYPE" == "movie" ]]; then
        BASE="$RADARR_URL"; KEY="$RADARR_API_KEY"; ENDPOINT="movie"
    else
        BASE="$SONARR_URL"; KEY="$SONARR_API_KEY"; ENDPOINT="series"
    fi

    # v2.1: no key configured -> warn instead of a doomed API call
    if [[ -z "$KEY" ]]; then
        log "             UNMONITOR: skipped (no API key configured - see config.env.example)"
        return 1
    fi

    # The heredoc is python's stdin, which also shields the outer
    # while-read loop's stdin from being consumed.
    # The API key is passed via the environment, NOT argv: argv is
    # world-readable through /proc/<pid>/cmdline, but /proc/<pid>/environ
    # is readable only by the owner and root.
    NAS_ARR_KEY="$KEY" python3 - "$BASE" "$ENDPOINT" "$ITEM_ID" "$NEW_PATH" <<'PYEOF'
import os, sys, json, urllib.request
base, endpoint, item_id, new_path = sys.argv[1:5]
key = os.environ["NAS_ARR_KEY"]
url = f"{base}/api/v3/{endpoint}/{item_id}"
headers = {"X-Api-Key": key, "Content-Type": "application/json"}
try:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        obj = json.loads(r.read().decode())
    obj["monitored"] = False
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
    print(f"unmonitor failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# --- VERIFIED MOVE (v2) --------------------------------------
# move_verified SRC DEST  -> 0 on verified move, 1 on failure
move_verified() {
    local SRC="$1"
    local DEST="$2"

    if [[ -d "$SRC" ]]; then
        # Copy (resumes partial destinations automatically)
        if ! rsync -a "$SRC/" "$DEST/" < /dev/null; then
            return 1
        fi
        # Checksum verify: any output means a file differs
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

MOVED_COUNT=0
ERROR_COUNT=0
SPACE_MOVED=0

# Oldest first, so a capacity-target run frees space with the
# stalest media (harmless ordering when no target is set)
TMPFILE=$(mktemp)
python3 -c "
import json
with open('$CANDIDATE_FILE') as f:
    data = json.load(f)
for c in data['candidates']:
    print(f\"{c['type']}\t{c['path']}\t{c['name']}\t{c['size_bytes']}\t{c.get('id','')}\t{c.get('age_days', 0)}\")
" | sort -t$'\t' -k6,6 -rn > "$TMPFILE"

# L4: pipefail is off, so sort's success would mask a python parse
# failure - check the emitter's status explicitly.
if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
    log "ERROR: could not parse candidate file $CANDIDATE_FILE (invalid JSON?)."
    log "Rerun cold_storage_scan.py to regenerate it."
    notify "cold_storage_cycle ERROR: candidate file parse failed ($CANDIDATE_FILE)"
    rm -f "$TMPFILE"
    exit 1
fi

TOTAL_ITEMS=$(wc -l < "$TMPFILE")
log "Total candidates to process: $TOTAL_ITEMS"
log ""

CURRENT=0
while IFS=$'\t' read -r TYPE SRC_PATH NAME SIZE_BYTES ITEM_ID AGE_DAYS; do
    ((CURRENT++))
    SIZE_BYTES=${SIZE_BYTES:-0}   # v2 FIX: guard empty value
    AGE_DAYS=${AGE_DAYS:-0}

    # v2.3 CAPACITY TARGET: stop once the pool is back at target.
    # SPACE_MOVED tracks recorded sizes, so this works identically
    # for dry runs (simulated) and live runs.
    if (( POOL_TARGET_PCT > 0 )); then
        EFFECTIVE_PCT=$(( (POOL_USED - SPACE_MOVED) * 100 / POOL_TOTAL ))
        if (( EFFECTIVE_PCT <= POOL_TARGET_PCT )); then
            log "Pool at ${EFFECTIVE_PCT}% <= target ${POOL_TARGET_PCT}% - stopping here."
            log "Remaining $(( TOTAL_ITEMS - CURRENT + 1 )) candidate(s) left on the hot pool."
            break
        fi
    fi

    # Translate container-style paths to real NAS host paths
    # (scan v2.1+ already outputs host paths; this is a no-op then)
    case "$SRC_PATH" in
        "$MOVIE_CONTAINER_PREFIX"*)
            SRC_PATH="${MOVIES_DIR%/}/${SRC_PATH#"$MOVIE_CONTAINER_PREFIX"}"
            ;;
        "$TV_CONTAINER_PREFIX"*)
            SRC_PATH="${TV_DIR%/}/${SRC_PATH#"$TV_CONTAINER_PREFIX"}"
            ;;
    esac

    if [[ "$TYPE" == "movie" ]]; then
        DEST_DIR="$COLD_MOVIES"
    else
        DEST_DIR="$COLD_TV"
    fi

    DEST_PATH="$DEST_DIR/$(basename "$SRC_PATH")"

    # Source gone + destination present = moved on a previous run
    if [[ ! -e "$SRC_PATH" && -e "$DEST_PATH" ]]; then
        log "[$CURRENT/$TOTAL_ITEMS] SKIP: $NAME (already moved previously)"
        continue
    fi

    if [[ ! -e "$SRC_PATH" ]]; then
        log "[$CURRENT/$TOTAL_ITEMS] SKIP: $NAME"
        log "             Source no longer exists: $SRC_PATH"
        ((ERROR_COUNT++))
        continue
    fi

    # v2.2 SIZE RE-VERIFY: if the item grew >20% since the scan,
    # it was probably quality-upgraded - the snapshot is wrong
    # for this item. Skip it; a fresh scan will re-evaluate.
    CUR_BYTES=$(du -sb "$SRC_PATH" 2>/dev/null | cut -f1)
    CUR_BYTES=${CUR_BYTES:-0}
    if (( SIZE_BYTES > 0 && CUR_BYTES > SIZE_BYTES + SIZE_BYTES / 5 )); then
        log "[$CURRENT/$TOTAL_ITEMS] SKIP: $NAME"
        log "             Source grew since scan ($SIZE_BYTES -> $CUR_BYTES bytes, quality upgrade?)"
        log "             Rerun cold_storage_scan.py to re-evaluate this item."
        ((ERROR_COUNT++))
        continue
    fi

    # v2 FIX: destination existing is no longer a blind skip.
    # rsync resumes/completes the partial copy and verifies it.
    if [[ -e "$DEST_PATH" ]]; then
        log "[$CURRENT/$TOTAL_ITEMS] RESUME: $NAME (partial destination found, completing + verifying)"
    else
        log "[$CURRENT/$TOTAL_ITEMS] $TYPE: $NAME (${AGE_DAYS}d old)"
    fi
    log "             FROM: $SRC_PATH"
    log "             TO:   $DEST_PATH"

    if [[ "$DRY_RUN" == false ]]; then
        if move_verified "$SRC_PATH" "$DEST_PATH"; then
            log "             STATUS: Moved + checksum verified OK"
            ((MOVED_COUNT++))
            SPACE_MOVED=$((SPACE_MOVED + SIZE_BYTES))
            ARR_PATH_UPDATED=false
            if [[ "$UNMONITOR" == true ]]; then
                if [[ "$UPDATE_ARR_PATHS" == true ]]; then
                    if unmonitor_item "$TYPE" "$ITEM_ID" "$DEST_PATH"; then
                        log "             UNMONITOR+PATH: OK ($TYPE id $ITEM_ID now points at cold storage)"
                        ARR_PATH_UPDATED=true
                    fi
                else
                    if unmonitor_item "$TYPE" "$ITEM_ID"; then
                        log "             UNMONITOR: OK ($TYPE id $ITEM_ID)"
                    fi
                fi
            fi
            if append_manifest "archived" "$TYPE" "$ITEM_ID" "$NAME" "$SRC_PATH" "$DEST_PATH" "$SIZE_BYTES" "$ARR_PATH_UPDATED"; then
                log "             MANIFEST: recorded in $MANIFEST_FILE"
            else
                log "             MANIFEST: WARNING - could not write $MANIFEST_FILE"
            fi
        else
            log "             STATUS: ERROR - move/verify failed, SOURCE KEPT"
            ((ERROR_COUNT++))
        fi
    else
        log "             STATUS: [DRY RUN] - no action taken"
        ((MOVED_COUNT++))
        SPACE_MOVED=$((SPACE_MOVED + SIZE_BYTES))
    fi
    log ""
done < "$TMPFILE"

rm -f "$TMPFILE"

SPACE_GB=$(awk "BEGIN {printf \"%.2f\", $SPACE_MOVED / 1073741824}")

log "=============================="
log "  SUMMARY"
log "  Total candidates: $TOTAL_ITEMS"
if [[ "$DRY_RUN" == true ]]; then
    log "  Items that WOULD move: $MOVED_COUNT"
    log "  Skipped/errors: $ERROR_COUNT"
    log "  Space that WOULD move: ~${SPACE_GB} GB"
    log "  Run with --run to execute"
    notify "cold_storage_cycle DRY RUN: $MOVED_COUNT item(s) would move (~${SPACE_GB} GB), $ERROR_COUNT skipped/errors"
else
    log "  Items moved (verified): $MOVED_COUNT"
    log "  Skipped/errors: $ERROR_COUNT"
    log "  Space moved: ~${SPACE_GB} GB"
    notify "cold_storage_cycle: moved $MOVED_COUNT item(s) (~${SPACE_GB} GB) to cold storage, $ERROR_COUNT skipped/errors"
fi
log "=============================="
log "Log saved to: $LOG_FILE"
