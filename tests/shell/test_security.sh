#!/bin/bash
# ============================================================
# test_security.sh
# Regression tests for the security hardening:
#   H1 - API keys travel via environment, never argv
#   M1 - config values are shell-escaped when written
#   M2 - a group/other-writable config.env is refused (it is
#        sourced, so writable == code execution)
#
# Usage: bash tests/shell/test_security.sh
# ============================================================
# SC2016: the single-quoted strings below are literal grep patterns
#   (we WANT $KEY / $2 unexpanded). SC1091: install.sh is sourced at
#   runtime to unit-test one of its functions; not statically followable.
# SC2317: helpers below are invoked indirectly through check().
# shellcheck disable=SC2016,SC1091,SC2317
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$REPO_DIR/scripts"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; ((PASS++)); else echo "  FAIL: $d"; ((FAIL++)); fi; }
# 0 when the string is ABSENT. -e/-- so a pattern starting with '-'
# is treated as a pattern, not a grep option.
not_grep() { ! grep -Fq -e "$1" -- "$2"; }
has_grep()  { grep -Fq -e "$1" -- "$2"; }

# --- H1: keys via env, not argv -----------------------------
echo "=== H1: API keys never passed as argv ==="
# The old, leaky pattern was:  python3 - "$BASE" "$KEY" ...
check "cycle does not pass key as argv" not_grep '- "$BASE" "$KEY"' "$SCRIPTS/cold_storage_cycle.sh"
check "restore does not pass key as argv" not_grep '- "$BASE" "$KEY"' "$SCRIPTS/cold_storage_restore.sh"
check "cycle passes key via NAS_ARR_KEY env" has_grep 'NAS_ARR_KEY="$KEY" python3' "$SCRIPTS/cold_storage_cycle.sh"
check "restore passes key via NAS_ARR_KEY env" has_grep 'NAS_ARR_KEY="$KEY" python3' "$SCRIPTS/cold_storage_restore.sh"
INSTALL_ENV_CALLS=$(grep -Fc 'NAS_ARR_KEY="$2" python3' "$REPO_DIR/install.sh")
check "installer passes key via env in arr + tautulli checks" test "$INSTALL_ENV_CALLS" -ge 2

# --- M1: config values are shell-escaped --------------------
echo "=== M1: set_config_value escapes shell metacharacters ==="
(
    set +u
    # shellcheck disable=SC1090
    source "$REPO_DIR/install.sh"
    CONFIG_PATH="$WORK/m1.env"
    printf 'QBT_PASSWORD="placeholder"\n' > "$CONFIG_PATH"
    nasty='p@ss"w$rd`echo pwned`\end'
    set_config_value QBT_PASSWORD "$nasty"
    # config.env must still parse, and the value must round-trip exactly
    got=$(bash -c "source '$CONFIG_PATH'; printf '%s' \"\$QBT_PASSWORD\"")
    [[ "$got" == "$nasty" ]]
) && M1_OK=0 || M1_OK=1
check "special-char value round-trips through config.env safely" test "$M1_OK" -eq 0

# --- M2: writable config.env refused ------------------------
echo "=== M2: group/other-writable config.env is refused ==="
BADCFG="$WORK/bad.env"
printf 'MOVIES_DIR="/tmp/x"\n' > "$BADCFG"
chmod 664 "$BADCFG"   # other-readable AND group-writable
OUT=$(CONFIG_FILE="$BADCFG" LOG_DIR="$WORK/logs" LOCK_DIR="$WORK" \
      bash "$SCRIPTS/duplicate_cleanup.sh" 2>&1)
RC=$?
check "writable config causes non-zero exit" test "$RC" -ne 0
check "writable config is reported clearly" grep -q "refusing to source" <<<"$OUT"

# A locked-down config (600) is accepted (sanity: guard is not overzealous)
GOODCFG="$WORK/good.env"
printf 'MOVIES_DIR="%s/empty"\n' "$WORK" > "$GOODCFG"
chmod 600 "$GOODCFG"
mkdir -p "$WORK/empty"
OUT=$(CONFIG_FILE="$GOODCFG" LOG_DIR="$WORK/logs" LOCK_DIR="$WORK" \
      bash "$SCRIPTS/duplicate_cleanup.sh" 2>&1)
check "mode-600 config is accepted" grep -q "duplicate_cleanup.sh" <<<"$OUT"

echo
echo "security tests: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
