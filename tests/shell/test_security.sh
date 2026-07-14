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
# SC2031: install.sh is deliberately sourced inside an isolation
#   subshell (M1 test); its var reassignments are contained on purpose.
# shellcheck disable=SC2016,SC1091,SC2317,SC2031
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

# --doctor must refuse a writable config too (it also sources it) -
# otherwise the scripts' guard is bypassable via the doctor.
DOCTOR_DIR="$WORK/doctor_install"
bash "$REPO_DIR/install.sh" --yes --dir "$DOCTOR_DIR" </dev/null >/dev/null 2>&1
chmod 660 "$DOCTOR_DIR/config.env"
OUT=$(bash "$DOCTOR_DIR/install.sh" --doctor </dev/null 2>&1)
RC=$?
check "doctor refuses writable config (non-zero exit)" test "$RC" -ne 0
check "doctor reports the refusal" grep -q "refusing to source" <<<"$OUT"

# A locked-down config (600) is accepted (sanity: guard is not overzealous)
GOODCFG="$WORK/good.env"
printf 'MOVIES_DIR="%s/empty"\n' "$WORK" > "$GOODCFG"
chmod 600 "$GOODCFG"
mkdir -p "$WORK/empty"
OUT=$(CONFIG_FILE="$GOODCFG" LOG_DIR="$WORK/logs" LOCK_DIR="$WORK" \
      bash "$SCRIPTS/duplicate_cleanup.sh" 2>&1)
check "mode-600 config is accepted" grep -q "duplicate_cleanup.sh" <<<"$OUT"

# --- M-A: webhook URLs never on a curl command line ----------
echo "=== M-A: webhook URLs via curl stdin config, not argv ==="
for f in "$SCRIPTS/cold_storage_cycle.sh" "$SCRIPTS/cold_storage_restore.sh"; do
    name=$(basename "$f")
    # No line may put curl and a webhook-URL variable together
    if grep -Eq 'curl.*(NTFY_URL|DISCORD_WEBHOOK_URL)|(NTFY_URL|DISCORD_WEBHOOK_URL).*curl' "$f"; then
        check "$name keeps webhook URLs off curl argv" false
    else
        check "$name keeps webhook URLs off curl argv" true
    fi
    check "$name feeds curl via stdin config (-K -)" grep -Fq -e '-K -' -- "$f"
done
# Functional: notify path with an unreachable URL still exits clean
export MOVIES_DIR_MA="$WORK/ma_movies"; mkdir -p "$MOVIES_DIR_MA"
OUT=$(NTFY_URL="http://127.0.0.1:9/t" MOVIES_DIR="$MOVIES_DIR_MA" TV_DIR="$MOVIES_DIR_MA" \
      COLD_ROOT="$WORK/ma_cold" CANDIDATE_FILE="$WORK/nope.json" \
      bash "$SCRIPTS/cold_storage_cycle.sh" 2>&1)
check "notify via -K - does not crash on unreachable URL" grep -q "Candidate file not found" <<<"$OUT"

# --- M-C: locks not in world-writable /tmp -------------------
echo "=== M-C: lock dir defaults to a user-owned location ==="
for f in "$SCRIPTS"/*.sh; do
    name=$(basename "$f")
    if grep -Fq 'LOCK_DIR:-${TMPDIR:-/tmp}' "$f"; then
        check "$name lock default is not /tmp" false
    else
        check "$name lock default is not /tmp" true
    fi
done
if grep -Fq '"LOCK_DIR": "/tmp"' "$SCRIPTS/cold_storage_scan.py" "$SCRIPTS/torrent_cleanup_api.py"; then
    check "python lock defaults are not /tmp" false
else
    check "python lock defaults are not /tmp" true
fi
# Functional: default lock dir is created on demand (no LOCK_DIR set)
DEFAULT_LOCK_DIR="$REPO_DIR/.locks"
OUT=$(env -u LOCK_DIR CONFIG_FILE="$WORK/config.env" LOG_DIR="$WORK/logs" \
      MOVIES_DIR="$MOVIES_DIR_MA" bash "$SCRIPTS/duplicate_cleanup.sh" 2>&1)
check "default .locks dir auto-created" test -d "$DEFAULT_LOCK_DIR"

# --- secret_scan: clean on repo, catches a planted key -------
echo "=== secret_scan.sh ==="
# Negative: the real repo must scan clean (the scanner must not
# self-match its own detection pattern).
check "secret_scan is clean on this repo" bash "$REPO_DIR/tests/secret_scan.sh"

# Positive: a planted key in a copied tree must be caught (proves
# the scan actually detects, not just that it exits 0).
TREE="$WORK/tree/tests"
mkdir -p "$TREE"
cp "$REPO_DIR/tests/secret_scan.sh" "$TREE/secret_scan.sh"
# Build the 32-hex fixture at RUNTIME so no 32-char hex literal lives
# in this tracked file (which secret_scan would otherwise flag).
fake_key=""
for _ in 1 2 3 4; do fake_key+="deadbeef"; done   # 32 hex chars
printf 'API = "%s"\n' "$fake_key" > "$WORK/tree/leak.py"
if bash "$TREE/secret_scan.sh" >/dev/null 2>&1; then
    check "secret_scan detects a planted key" false
else
    check "secret_scan detects a planted key" true
fi

echo
echo "security tests: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
