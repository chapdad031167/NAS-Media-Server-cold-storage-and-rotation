#!/bin/bash
# ============================================================
# torrent_cleanup.sh v1.3
# Compares $TORRENT_MOVIES_DIR and $TORRENT_TV_DIR against the
# media library. Deletes confirmed-imported items.
#
# Categories:
#   IMPORTED    = match found in media library -> delete
#   UNMATCHED   = no match found -> report only, never touched
#   DOWNLOADING = contains .!qB files -> skipped, never touched
#
# Fixes in v1.3:
#   - flock lock file prevents overlapping runs.
#   - Old logs pruned after LOG_RETENTION_DAYS (default 90).
#
# Fixes in v1.2:
#   - Hardcoded paths moved to config.env / environment.
#
# Fixes in v1.1:
#   - Checks rm exit status instead of logging DELETED OK
#     unconditionally.
#   - Skips items still actively downloading (.!qB present).
#   - Guarded BYTES against empty value (du failure).
#
# WARNING: This deletes torrent data directly off disk. If
# qBittorrent still has these torrents loaded, you WILL get
# missing-file errors and broken seeds (H&R risk on private
# trackers). Prefer the qBittorrent-API version (v3) which
# removes the torrent properly. Only run this version when
# qBittorrent's list is already clean or seeding is done.
#
# Usage:
#   bash torrent_cleanup.sh          <- dry run (default)
#   bash torrent_cleanup.sh --run    <- live deletion
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

TORRENT_MOVIES="${TORRENT_MOVIES_DIR:-/volume1/Torrents/movies}"
TORRENT_TV="${TORRENT_TV_DIR:-/volume1/Torrents/tv}"
MEDIA_MOVIES="${MOVIES_DIR:-/volume1/Movies}"
MEDIA_TV="${TV_DIR:-/volume1/TV Shows}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/../logs}"
LOG_FILE="$LOG_DIR/torrent_cleanup_$(date +%Y%m%d_%H%M%S).log"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-90}"
# Locks default to a user-owned dir inside the install, not /tmp:
# predictable names in world-writable /tmp invite lock-squatting.
LOCK_DIR="${LOCK_DIR:-$SCRIPT_DIR/../.locks}"
DRY_RUN=true

if [[ "$1" == "--run" ]]; then
    DRY_RUN=false
fi

# Refuse to run concurrently (fd 9 holds the lock for the
# lifetime of the script)
mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/nas_media_torrent_cleanup.lock"
if ! flock -n 9; then
    echo "ERROR: another torrent_cleanup.sh is already running. Exiting." >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
find "$LOG_DIR" -maxdepth 1 -name '*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

normalize() {
    local str="$1"
    str="${str%.*}"
    str="${str,,}"
    str="${str// - / }"
    str="${str//./ }"
    str="${str//_/ }"
    # Strip SxxExx and everything after (TV episode files)
    str=$(echo "$str" | sed -E 's/s[0-9]{1,2}e[0-9]{1,2}.*//')
    # Strip bare season tags like S01, S02 (season packs)
    str=$(echo "$str" | sed -E 's/\bs[0-9]{1,2}\b.*//')
    # Strip dated episode patterns like 2026 06 27
    str=$(echo "$str" | sed -E 's/[0-9]{4} [0-9]{2} [0-9]{2}.*//')
    # Strip quality/codec tags and everything after
    str=$(echo "$str" | sed -E \
        's/\b(2160p|1080p|1080i|720p|480p|4k|uhd|hdr10\+|hdr10|hdr|dv|bluray|blu-ray|bdrip|brrip|web-dl|webdl|webrip|web|hdtv|dvdrip|xvid|x264|x265|h264|h265|hevc|avc|aac|ac3|dts|truehd|atmos|remux|proper|repack|extended|theatrical|directors|unrated|remastered|amzn|nf|max|dsnp|hulu|peacock|multi|german|french|spanish|italian|dl|subs|subbed|dubbed|10bit|8bit)\b.*//')
    str=$(echo "$str" | sed -E 's/\[[^\]]*\]//g' | sed -E 's/\([^)]*\)//g')
    str=$(echo "$str" | sed -E 's/\b(19|20)[0-9]{2}\b//g')
    str=$(echo "$str" | sed -E 's/-[a-zA-Z0-9]+$//')
    str=$(echo "$str" | tr -s ' ' | sed 's/^ //;s/ $//')
    echo "$str"
}

# Index all media folder names -> normalized map
declare -A MEDIA_MOVIE_MAP
declare -A MEDIA_TV_MAP

while IFS= read -r -d $'\0' folder; do
    name=$(basename "$folder")
    norm=$(normalize "$name")
    [[ -n "$norm" ]] && MEDIA_MOVIE_MAP["$norm"]="$name"
done < <(find "$MEDIA_MOVIES" -maxdepth 1 -mindepth 1 -type d -print0)

while IFS= read -r -d $'\0' folder; do
    name=$(basename "$folder")
    norm=$(normalize "$name")
    [[ -n "$norm" ]] && MEDIA_TV_MAP["$norm"]="$name"
done < <(find "$MEDIA_TV" -maxdepth 1 -mindepth 1 -type d -print0)

log "=============================="
log "  torrent_cleanup.sh v1.3"
log "  DRY_RUN: $DRY_RUN"
log "  Movies indexed: ${#MEDIA_MOVIE_MAP[@]} folders"
log "  TV Shows indexed: ${#MEDIA_TV_MAP[@]} folders"
log "=============================="
log ""

IMPORTED_COUNT=0
UNMATCHED_COUNT=0
DOWNLOADING_COUNT=0
SPACE_FREED=0

process_item() {
    local ITEM_NAME="$1"
    local TORRENT_DIR="$2"
    local MAP_TYPE="$3"

    local FULL_PATH="$TORRENT_DIR/$ITEM_NAME"

    # v1.1 FIX: never touch items qBittorrent is still writing
    if [[ -d "$FULL_PATH" ]] && \
       find "$FULL_PATH" -name '*.!qB' -print -quit 2>/dev/null | grep -q .; then
        log "  [DOWNLOADING] $ITEM_NAME - active .!qB files, skipping"
        log ""
        ((DOWNLOADING_COUNT++))
        return
    fi
    if [[ -f "$FULL_PATH" && "$FULL_PATH" == *'.!qB' ]]; then
        log "  [DOWNLOADING] $ITEM_NAME - active download, skipping"
        log ""
        ((DOWNLOADING_COUNT++))
        return
    fi

    local NORM
    NORM=$(normalize "$ITEM_NAME")
    local SIZE
    SIZE=$(du -sh "$FULL_PATH" 2>/dev/null | cut -f1)
    local BYTES
    BYTES=$(du -sb "$FULL_PATH" 2>/dev/null | cut -f1)
    BYTES=${BYTES:-0}   # v1.1 FIX: guard empty value

    local MATCHED=""
    if [[ "$MAP_TYPE" == "movie" ]]; then
        MATCHED="${MEDIA_MOVIE_MAP[$NORM]}"
    else
        MATCHED="${MEDIA_TV_MAP[$NORM]}"
    fi

    if [[ -n "$MATCHED" ]]; then
        log "  [IMPORTED]  $ITEM_NAME ($SIZE)"
        log "              matched: $MATCHED"
        if [[ "$DRY_RUN" == false ]]; then
            # v1.1 FIX: check rm actually succeeded
            if rm -rf -- "$FULL_PATH"; then
                log "              DELETED OK"
                SPACE_FREED=$((SPACE_FREED + BYTES))
                ((IMPORTED_COUNT++))
            else
                log "              ERROR - delete failed"
            fi
        else
            log "              [DRY RUN] would delete"
            SPACE_FREED=$((SPACE_FREED + BYTES))
            ((IMPORTED_COUNT++))
        fi
    else
        log "  [UNMATCHED] $ITEM_NAME ($SIZE)"
        log "              normalized key: \"$NORM\""
        ((UNMATCHED_COUNT++))
    fi
    log ""
}

log "--- MOVIES ---"
while IFS= read -r -d $'\0' item; do
    process_item "$(basename "$item")" "$TORRENT_MOVIES" "movie"
done < <(find "$TORRENT_MOVIES" -maxdepth 1 -mindepth 1 -print0 | sort -z)

log "--- TV ---"
while IFS= read -r -d $'\0' item; do
    process_item "$(basename "$item")" "$TORRENT_TV" "tv"
done < <(find "$TORRENT_TV" -maxdepth 1 -mindepth 1 -print0 | sort -z)

SPACE_GB=$(awk "BEGIN {printf \"%.2f\", $SPACE_FREED / 1073741824}")

log "=============================="
log "  SUMMARY"
log "  IMPORTED (deletable):  $IMPORTED_COUNT"
log "  UNMATCHED (kept):      $UNMATCHED_COUNT"
log "  DOWNLOADING (kept):    $DOWNLOADING_COUNT"
if [[ "$DRY_RUN" == true ]]; then
    log "  Space that WOULD be freed: ~${SPACE_GB} GB"
    log "  Run with --run to execute"
else
    log "  Space freed: ~${SPACE_GB} GB"
fi
log "=============================="
log "Log saved to: $LOG_FILE"
