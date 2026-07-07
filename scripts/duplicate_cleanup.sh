#!/bin/bash
# ============================================================
# duplicate_cleanup.sh v1.3
# Finds duplicate movies in $MOVIES_DIR (same title AND
# year, multiple files). Keeps the LARGEST file (highest
# quality), flags the rest for deletion.
#
# Fixes in v1.3:
#   - Hardcoded paths moved to config.env / environment.
#
# Fixes in v1.2:
#   - extract_year: replaced `dirname | xargs basename` with
#     basename "$(dirname ...)". xargs breaks on apostrophes
#     (e.g. "Child's Play (1988)"), corrupting the group key.
#   - Guarded FILE_BYTES against empty value (du failure)
#     which previously caused a bash arithmetic error.
#   - Removed dead `export -f normalize_title`.
#
# Fixes in v1.1:
#   - Year included in group key (prevents same-title/diff-year
#     false positives like Halloween 1978 vs 2007)
#   - Skips files inside Featurettes/ subdirectories
#
# Usage:
#   bash duplicate_cleanup.sh          <- dry run (safe, default)
#   bash duplicate_cleanup.sh --run    <- live deletion
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090  # user-supplied config, path known only at runtime
    source "$CONFIG_FILE"
fi

MOVIES_DIR="${MOVIES_DIR:-/volume1/Movies}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/../logs}"
LOG_FILE="$LOG_DIR/duplicate_cleanup_$(date +%Y%m%d_%H%M%S).log"
DRY_RUN=true

if [[ "$1" == "--run" ]]; then
    DRY_RUN=false
fi

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=============================="
log "  duplicate_cleanup.sh v1.3"
log "  DRY_RUN: $DRY_RUN"
log "  Target: $MOVIES_DIR"
log "=============================="

PAIRS_FOUND=0
FILES_DELETED=0
SPACE_RECOVERED=0

TMPFILE=$(mktemp)

# Find all video files, skip anything inside Featurettes/
# Behind the Scenes/ Extras/ Interviews/ Scenes/ Shorts/ Trailers/
find "$MOVIES_DIR" -type f \( \
    -iname "*.mkv" -o \
    -iname "*.mp4" -o \
    -iname "*.avi" -o \
    -iname "*.m4v" -o \
    -iname "*.mov" \
\) -printf "%s\t%p\n" | grep -viE \
    '/(featurettes|behind.the.scenes|extras|interviews|scenes|shorts|trailers|deleted.scenes|behind-the-scenes)/'\
    > "$TMPFILE"

log "Total video files found (excl. featurettes): $(wc -l < "$TMPFILE")"
log ""

normalize_title() {
    local str="$1"
    str="${str,,}"
    str=$(echo "$str" | sed -E \
        's/\b(2160p|1080p|1080i|720p|480p|4k|uhd|hdr|hdr10|dv|bluray|blu-ray|bdrip|brrip|web-dl|webdl|webrip|web|hdtv|dvdrip|dvd|xvid|x264|x265|h264|h265|hevc|avc|aac|ac3|dts|truehd|atmos|remux|proper|repack|extended|theatrical|directors|unrated|remastered)\b//gI')
    str=$(echo "$str" | sed -E 's/\[[^\]]*\]//g')
    str=$(echo "$str" | sed -E 's/\(?[0-9]{4}\)?//g')
    str=$(echo "$str" | sed -E 's/[._\-]+/ /g' | tr -s ' ' | sed 's/^ //;s/ $//')
    echo "$str"
}

extract_year() {
    local filepath="$1"
    local folder
    # v1.2 FIX: basename "$(dirname ...)" instead of xargs.
    # xargs fails on apostrophes in folder names.
    folder=$(basename "$(dirname "$filepath")")
    local year
    year=$(echo "$folder" | grep -oE '\(([0-9]{4})\)' | grep -oE '[0-9]{4}' | tail -1)
    if [[ -z "$year" ]]; then
        year=$(basename "$filepath" | grep -oE '\b(19|20)[0-9]{2}\b' | head -1)
    fi
    echo "${year:-0000}"
}

declare -A TITLE_MAP

while IFS=$'\t' read -r SIZE FILEPATH; do
    NORM=$(normalize_title "$(basename "$FILEPATH")")
    YEAR=$(extract_year "$FILEPATH")
    KEY="${NORM}__${YEAR}"

    if [[ -n "${TITLE_MAP[$KEY]}" ]]; then
        TITLE_MAP[$KEY]="${TITLE_MAP[$KEY]}"$'\n'"$SIZE"$'\t'"$FILEPATH"
    else
        TITLE_MAP[$KEY]="$SIZE"$'\t'"$FILEPATH"
    fi
done < "$TMPFILE"

rm -f "$TMPFILE"

for KEY in "${!TITLE_MAP[@]}"; do
    GROUP="${TITLE_MAP[$KEY]}"
    COUNT=$(echo "$GROUP" | wc -l)

    if [[ $COUNT -lt 2 ]]; then
        continue
    fi

    ((PAIRS_FOUND++))
    DISPLAY_KEY="${KEY%__*} (${KEY##*__})"
    log "--- Duplicate group: \"$DISPLAY_KEY\" ($COUNT files) ---"

    SORTED=$(echo "$GROUP" | sort -t$'\t' -k1 -rn)
    KEEP=$(echo "$SORTED" | head -1 | cut -f2-)
    TO_DELETE=$(echo "$SORTED" | tail -n +2 | cut -f2-)

    KEEP_SIZE=$(echo "$SORTED" | head -1 | cut -f1)
    log "  KEEP:   $KEEP ($(numfmt --to=iec "$KEEP_SIZE" 2>/dev/null || echo "${KEEP_SIZE}B"))"

    while IFS= read -r DELETE_FILE; do
        FILE_SIZE=$(du -sh "$DELETE_FILE" 2>/dev/null | cut -f1)
        FILE_BYTES=$(du -b "$DELETE_FILE" 2>/dev/null | cut -f1)
        FILE_BYTES=${FILE_BYTES:-0}   # v1.2 FIX: guard empty value
        log "  DELETE: $DELETE_FILE ($FILE_SIZE)"

        if [[ "$DRY_RUN" == false ]]; then
            if rm -f -- "$DELETE_FILE"; then
                log "  STATUS: Deleted OK"
                ((FILES_DELETED++))
                SPACE_RECOVERED=$((SPACE_RECOVERED + FILE_BYTES))
                PARENT_DIR=$(dirname "$DELETE_FILE")
                if [[ "$PARENT_DIR" != "$MOVIES_DIR" ]]; then
                    rmdir --ignore-fail-on-non-empty "$PARENT_DIR" 2>/dev/null
                fi
            else
                log "  STATUS: ERROR - could not delete"
            fi
        else
            log "  STATUS: [DRY RUN] - no action taken"
            ((FILES_DELETED++))
            SPACE_RECOVERED=$((SPACE_RECOVERED + FILE_BYTES))
        fi
    done <<< "$TO_DELETE"

    log ""
done

SPACE_GB=$(awk "BEGIN {printf \"%.2f\", $SPACE_RECOVERED / 1073741824}")

log "=============================="
log "  SUMMARY"
log "  Duplicate groups found: $PAIRS_FOUND"
if [[ "$DRY_RUN" == true ]]; then
    log "  Files that WOULD be deleted: $FILES_DELETED"
    log "  Space that WOULD be recovered: ~${SPACE_GB} GB"
    log "  Run with --run flag to execute"
else
    log "  Files deleted: $FILES_DELETED"
    log "  Space recovered: ~${SPACE_GB} GB"
fi
log "=============================="
log "Log saved to: $LOG_FILE"
