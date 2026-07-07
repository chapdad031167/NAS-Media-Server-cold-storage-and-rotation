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
# Same container on both copies: the group key keeps the file
# extension, so a .mkv and a .mp4 of the same film do not group.
mkfile "$MOVIES_DIR/Heat (1995)/Heat.1995.1080p.mkv" 4096
mkfile "$MOVIES_DIR/Heat (1995)/Heat.1995.720p.mkv" 1024
mkfile "$MOVIES_DIR/Halloween (1978)/Halloween.1978.1080p.mkv" 2048
mkfile "$MOVIES_DIR/Halloween (2007)/Halloween.2007.1080p.mkv" 2048

OUT=$(bash "$SCRIPTS/duplicate_cleanup.sh")
check "dry run is the default" grep -q "DRY_RUN: true" <<<"$OUT"
check "dry run deletes nothing" test -f "$MOVIES_DIR/Heat (1995)/Heat.1995.720p.mkv"
check "duplicate group detected" grep -q -- "--- Duplicate group:" <<<"$OUT"

OUT=$(bash "$SCRIPTS/duplicate_cleanup.sh" --run)
check "--run deletes the smaller duplicate" test ! -f "$MOVIES_DIR/Heat (1995)/Heat.1995.720p.mkv"
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
python3 - "$CANDIDATE_FILE" "$SRC" <<'PYEOF'
import json, os, sys
size = sum(os.path.getsize(os.path.join(r, f))
           for r, _, fs in os.walk(sys.argv[2]) for f in fs)
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

OUT=$(bash "$SCRIPTS/cold_storage_cycle.sh" --run)
check "--run moves source to cold storage" test ! -e "$SRC"
check "--run destination exists" test -f "$COLD_ROOT/Movies/Old Drama (2010)/Old.Drama.2010.1080p.mkv"
check "move is checksum verified" grep -q "checksum verified OK" <<<"$OUT"
check "unmonitor skipped without API key" grep -q "UNMONITOR: skipped (no API key" <<<"$OUT"

echo
echo "shell tests: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
