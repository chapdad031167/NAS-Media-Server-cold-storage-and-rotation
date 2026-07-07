#!/bin/bash
# ============================================================
# cold_storage_cycle.sh v2.2
# Reads the candidate JSON produced by cold_storage_scan.py and
# moves each candidate to cold storage.
#   Movies -> $COLD_ROOT/Movies/
#   TV     -> $COLD_ROOT/TV Shows/
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
DRY_RUN=true

# Unmonitor moved items in Radarr/Sonarr (recommended: true)
UNMONITOR="${UNMONITOR:-true}"
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

if [[ ! -f "$CANDIDATE_FILE" ]]; then
    log "ERROR: Candidate file not found: $CANDIDATE_FILE"
    log "Run cold_storage_scan.py first."
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

log "=============================="
log "  cold_storage_cycle.sh v2.2"
log "  DRY_RUN: $DRY_RUN"
log "  UNMONITOR: $UNMONITOR"
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
TOTAL_NEEDED=$(python3 -c "
import json
with open('$CANDIDATE_FILE') as f:
    data = json.load(f)
print(data.get('total_size_bytes', 0))
")
COLD_AVAIL=$(df -PB1 "$COLD_ROOT" 2>/dev/null | awk 'NR==2{print $4}')
COLD_AVAIL=${COLD_AVAIL:-0}
NEEDED_WITH_HEADROOM=$(( TOTAL_NEEDED + TOTAL_NEEDED / 20 ))

log "Preflight: need $(awk "BEGIN {printf \"%.2f\", $TOTAL_NEEDED/1073741824}") GB (+5% headroom), cold drive has $(awk "BEGIN {printf \"%.2f\", $COLD_AVAIL/1073741824}") GB free"
if [[ "$COLD_AVAIL" -lt "$NEEDED_WITH_HEADROOM" ]]; then
    log "ERROR: Not enough free space on cold storage. Aborting."
    exit 1
fi
log ""

# --- UNMONITOR HELPER (v2) -----------------------------------
# unmonitor_item TYPE ID  -> sets monitored=false in Radarr/Sonarr
unmonitor_item() {
    local ITEM_TYPE="$1"
    local ITEM_ID="$2"

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
    python3 - "$BASE" "$KEY" "$ENDPOINT" "$ITEM_ID" <<'PYEOF'
import sys, json, urllib.request
base, key, endpoint, item_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
url = f"{base}/api/v3/{endpoint}/{item_id}"
headers = {"X-Api-Key": key, "Content-Type": "application/json"}
try:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        obj = json.loads(r.read().decode())
    obj["monitored"] = False
    data = json.dumps(obj).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="PUT")
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

TMPFILE=$(mktemp)
python3 -c "
import json
with open('$CANDIDATE_FILE') as f:
    data = json.load(f)
for c in data['candidates']:
    print(f\"{c['type']}\t{c['path']}\t{c['name']}\t{c['size_bytes']}\t{c.get('id','')}\")
" > "$TMPFILE"

TOTAL_ITEMS=$(wc -l < "$TMPFILE")
log "Total candidates to process: $TOTAL_ITEMS"
log ""

CURRENT=0
while IFS=$'\t' read -r TYPE SRC_PATH NAME SIZE_BYTES ITEM_ID; do
    ((CURRENT++))
    SIZE_BYTES=${SIZE_BYTES:-0}   # v2 FIX: guard empty value

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
        log "[$CURRENT/$TOTAL_ITEMS] $TYPE: $NAME"
    fi
    log "             FROM: $SRC_PATH"
    log "             TO:   $DEST_PATH"

    if [[ "$DRY_RUN" == false ]]; then
        if move_verified "$SRC_PATH" "$DEST_PATH"; then
            log "             STATUS: Moved + checksum verified OK"
            ((MOVED_COUNT++))
            SPACE_MOVED=$((SPACE_MOVED + SIZE_BYTES))
            if [[ "$UNMONITOR" == true ]]; then
                if unmonitor_item "$TYPE" "$ITEM_ID"; then
                    log "             UNMONITOR: OK ($TYPE id $ITEM_ID)"
                fi
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
else
    log "  Items moved (verified): $MOVED_COUNT"
    log "  Skipped/errors: $ERROR_COUNT"
    log "  Space moved: ~${SPACE_GB} GB"
fi
log "=============================="
log "Log saved to: $LOG_FILE"
