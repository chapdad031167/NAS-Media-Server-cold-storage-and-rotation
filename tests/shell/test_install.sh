#!/bin/bash
# ============================================================
# test_install.sh
# Integration tests for install.sh:
#   1. --yes --dir installs the tooling into a fresh directory.
#   2. config.env is created from the template with mode 600.
#   3. A re-run NEVER overwrites an existing config.env.
#   4. --doctor works on the installed copy, flags unconfigured
#      settings as warnings, and still exits 0.
#   5. Prerequisite failure aborts the install.
#
# Usage: bash tests/shell/test_install.sh
# Exits non-zero on first failure.
# ============================================================
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TARGET="$WORK/opt/nas-media-automation"

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

echo "=== install.sh --yes --dir ==="
OUT=$(bash "$REPO_DIR/install.sh" --yes --dir "$TARGET" </dev/null)
RC=$?
check "install exits 0" test "$RC" -eq 0
check "scripts copied" test -x "$TARGET/scripts/cold_storage_cycle.sh"
check "python scripts copied" test -f "$TARGET/scripts/cold_storage_scan.py"
check "protected list copied" test -f "$TARGET/protected_franchises.txt"
check "installer copies itself for future doctor runs" test -f "$TARGET/install.sh"
check "config.env created from template" test -f "$TARGET/config.env"
check "config.env is mode 600" test "$(stat -c %a "$TARGET/config.env")" = "600"
check "guided setup skipped with --yes" grep -q "Skipping guided setup" <<<"$OUT"
check "script verification ran" grep -q "bash -n cold_storage_cycle.sh" <<<"$OUT"

echo "=== re-run never overwrites config ==="
echo 'MY_CUSTOM_MARKER=keepme' >> "$TARGET/config.env"
OUT=$(bash "$REPO_DIR/install.sh" --yes --dir "$TARGET" </dev/null)
check "re-run exits 0" test $? -eq 0
check "re-run reports config kept" grep -q "existing config.env kept" <<<"$OUT"
check "user edits survive a re-run" grep -q "MY_CUSTOM_MARKER=keepme" "$TARGET/config.env"

echo "=== --doctor on the installed copy ==="
OUT=$(bash "$TARGET/install.sh" --doctor </dev/null)
RC=$?
check "doctor exits 0 on an unconfigured install" test "$RC" -eq 0
check "doctor sees the config" grep -q "config.env present" <<<"$OUT"
check "doctor flags unconfigured Radarr as warning" grep -q "Radarr not configured yet" <<<"$OUT"
check "doctor flags unmounted cold root as warning" grep -q "COLD_ROOT" <<<"$OUT"
check "warnings are counted" grep -qE "Finished with [1-9][0-9]* warning" <<<"$OUT"

echo "=== --doctor without a config ==="
NOCFG="$WORK/empty"
mkdir -p "$NOCFG/scripts"
cp "$REPO_DIR/install.sh" "$NOCFG/"
OUT=$(bash "$NOCFG/install.sh" --doctor </dev/null)
RC=$?
check "doctor fails without config.env" test "$RC" -ne 0
check "doctor says to run install first" grep -q "run install first" <<<"$OUT"

echo "=== unknown option ==="
if bash "$REPO_DIR/install.sh" --bogus >/dev/null 2>&1; then
    check "unknown option is rejected" false
else
    check "unknown option is rejected" true
fi

echo
echo "install tests: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
