#!/bin/bash
# ============================================================
# test_dry_run.sh
# Integration tests for the three bash scripts, run against a
# throwaway fixture tree. Verifies the safety contract:
#   1. Every script defaults to dry-run and touches NOTHING.
#   2. --run performs the destructive operation.
#   3. duplicate_cleanup groups by title AND year (Halloween
#      1978 vs 2007 are not duplicates of each other).
#   4. torrent_cleanup never touches UNMATCHED or DOWNLOADING.
#   5. cold_storage_cycle moves + verifies, and skips
#      unmonitor gracefully when no API key is configured.
#
# Usage: bash tests/shell/test_dry_run.sh
# Exits non-zero on first failure.
# ============================================================
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$REPO_DIR/scripts"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Point every script at an empty config so host config.env (if
# any) can't leak into the tests.
export CONFIG_FILE="$WORK/config.env"
touch "$CONFIG_FILE"
export LOG_DIR="$WORK/logs"
export LOCK_DIR="$WORK"

PASS=0
FAIL=0

check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@"; then
        echo "  ok: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
    fi
}

mkfile() { # mkfile <path> <size>
    mkdir -p "$(dirname "$1")"
    head -c "$2" /dev/urandom > "$1"
}

# --- duplicate_cleanup.sh -----------------------------------
echo "=== duplicate_cleanup.sh ==="
export MOVIES_DIR="$WORK/Movies"
# v1.4: the group key strips the extension, so a .mkv and an
# .mp4 of the same film ARE duplicates of each other now.
mkfile "$MOVIES_DIR/Heat (1995)/Heat.1995.1080p.mkv" 4096
mkfile "$MOVIES_DIR/Heat (1995)/Heat.1995.720p.mp4" 1024
mkfile "$MOVIES_DIR/Halloween (1978)/Halloween.1978.1080p.mkv" 2048
mkfile "$MOVIES_DIR/Halloween (2007)/Halloween.2007.1080p.mkv" 2048

# Log retention: logs older than LOG_RETENTION_DAYS are pruned
mkdir -p "$LOG_DIR"
touch -d "100 days ago" "$LOG_DIR/ancient_run.log"
touch "$LOG_DIR/recent_run.log"

# Locking: a held lock must refuse a second instance
exec 8>"$LOCK_DIR/nas_media_duplicate_cleanup.lock"
flock -n 8
if bash "$SCRIPTS/duplicate_cleanup.sh" >/dev/null 2>&1; then
    check "concurrent run refused while lock held" false
else
    check "concurrent run refused while lock held" true
fi
exec 8>&-

OUT=$(bash "$SCRIPTS/duplicate_cleanup.sh")
check "dry run is the default" grep -q "DRY_RUN: true" <<<"$OUT"
check "dry run deletes nothing" test -f "$MOVIES_DIR/Heat (1995)/Heat.1995.720p.mp4"
check "cross-container duplicate group detected" grep -q -- "--- Duplicate group:" <<<"$OUT"
check "old log pruned" test ! -f "$LOG_DIR/ancient_run.log"
check "recent log kept" test -f "$LOG_DIR/recent_run.log"

OUT=$(bash "$SCRIPTS/duplicate_cleanup.sh" --run)
check "--run deletes the smaller duplicate (mp4 vs mkv)" test ! -f "$MOVIES_DIR/Heat (1995)/Heat.1995.720p.mp4"
check "--run keeps the larger duplicate" test -f "$MOVIES_DIR/Heat (1995)/Heat.1995.1080p.mkv"
check "Halloween 1978 kept (year in group key)" test -f "$MOVIES_DIR/Halloween (1978)/Halloween.1978.1080p.mkv"
check "Halloween 2007 kept (year in group key)" test -f "$MOVIES_DIR/Halloween (2007)/Halloween.2007.1080p.mkv"

# --- torrent_cleanup.sh -------------------------------------
echo "=== torrent_cleanup.sh ==="
export TORRENT_MOVIES_DIR="$WORK/Torrents/movies"
export TORRENT_TV_DIR="$WORK/Torrents/tv"
export TV_DIR="$WORK/TV Shows"
mkdir -p "$TV_DIR" "$TORRENT_TV_DIR"
mkfile "$TORRENT_MOVIES_DIR/Heat.1995.1080p.BluRay.x264-GRP/heat.mkv" 1024      # imported
mkfile "$TORRENT_MOVIES_DIR/Unknown.Film.2024.1080p-GRP/film.mkv" 1024          # unmatched
mkfile "$TORRENT_MOVIES_DIR/Busy.Movie.2025.1080p-GRP/movie.mkv.!qB" 1024       # downloading

OUT=$(bash "$SCRIPTS/torrent_cleanup.sh")
check "dry run is the default" grep -q "DRY_RUN: true" <<<"$OUT"
check "dry run deletes nothing" test -d "$TORRENT_MOVIES_DIR/Heat.1995.1080p.BluRay.x264-GRP"
check "imported item matched" grep -q "\[IMPORTED\]  Heat" <<<"$OUT"

OUT=$(bash "$SCRIPTS/torrent_cleanup.sh" --run)
check "--run deletes imported item" test ! -e "$TORRENT_MOVIES_DIR/Heat.1995.1080p.BluRay.x264-GRP"
check "--run keeps unmatched item" test -d "$TORRENT_MOVIES_DIR/Unknown.Film.2024.1080p-GRP"
check "--run keeps downloading item" test -f "$TORRENT_MOVIES_DIR/Busy.Movie.2025.1080p-GRP/movie.mkv.!qB"

# --- cold_storage_cycle.sh ----------------------------------
echo "=== cold_storage_cycle.sh ==="
export COLD_ROOT="$WORK/Cold"
export CANDIDATE_FILE="$WORK/candidates.json"
mkdir -p "$COLD_ROOT"
mkfile "$MOVIES_DIR/Old Drama (2010)/Old.Drama.2010.1080p.mkv" 8192
SRC="$MOVIES_DIR/Old Drama (2010)"
# Record the size the same way the cycle script re-measures it
# (du -sb), so the size re-verify guard sees a clean baseline.
SRC_BYTES=$(du -sb "$SRC" | cut -f1)
python3 - "$CANDIDATE_FILE" "$SRC" "$SRC_BYTES" <<'PYEOF'
import json, sys
size = int(sys.argv[3])
json.dump({
    "total_size_bytes": size,
    "candidates": [{
        "type": "movie", "id": 42, "path": sys.argv[2],
        "name": "Old Drama", "size_bytes": size,
    }],
}, open(sys.argv[1], "w"))
PYEOF

OUT=$(bash "$SCRIPTS/cold_storage_cycle.sh")
check "dry run is the default" grep -q "DRY_RUN: true" <<<"$OUT"
check "dry run moves nothing" test -d "$SRC"
check "dry run creates nothing in cold storage" test ! -e "$COLD_ROOT/Movies/Old Drama (2010)"

# Staleness guard: an old candidate file warns on dry run and
# hard-refuses --run
touch -d "10 days ago" "$CANDIDATE_FILE"
OUT=$(bash "$SCRIPTS/cold_storage_cycle.sh")
check "stale candidates warn on dry run" grep -q "WARNING: Candidate file is" <<<"$OUT"
if bash "$SCRIPTS/cold_storage_cycle.sh" --run >/dev/null 2>&1; then
    check "stale candidates refuse --run" false
else
    check "stale candidates refuse --run" true
fi
check "stale refusal moved nothing" test -d "$SRC"
touch "$CANDIDATE_FILE"

# Size re-verify: source that grew >20% since the scan is skipped
mkfile "$SRC/extras.bonus.mkv" 65536
OUT=$(bash "$SCRIPTS/cold_storage_cycle.sh" --run)
check "grown source skipped" grep -q "Source grew since scan" <<<"$OUT"
check "grown source kept on disk" test -d "$SRC"
rm -f "$SRC/extras.bonus.mkv"

OUT=$(bash "$SCRIPTS/cold_storage_cycle.sh" --run)
check "--run moves source to cold storage" test ! -e "$SRC"
check "--run destination exists" test -f "$COLD_ROOT/Movies/Old Drama (2010)/Old.Drama.2010.1080p.mkv"
check "move is checksum verified" grep -q "checksum verified OK" <<<"$OUT"
check "unmonitor skipped without API key" grep -q "UNMONITOR: skipped (no API key" <<<"$OUT"

echo
echo "shell tests: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
