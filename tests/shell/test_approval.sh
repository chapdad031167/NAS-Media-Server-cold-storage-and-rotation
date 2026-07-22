#!/bin/bash
# ============================================================
# test_approval.sh
# Integration tests for approval_poll.sh, run against a stub
# cold_storage_cycle.sh and a fake curl (no network). Verifies
# the one-tap approval safety contract:
#   1. Disarmed by default: no config -> no poll, no cycle.
#   2. Armed but incomplete config fails loudly.
#   3. A group/other-writable config.env is refused.
#   4. Only the exact APPROVE_TOKEN triggers the cycle; other
#      messages are ignored but still advance the state file.
#   5. Replay-proof: the next poll resumes after the last seen
#      message id, so one tap can't archive twice.
#
# Usage: bash tests/shell/test_approval.sh
# Exits non-zero on any failure.
# ============================================================
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$REPO_DIR/scripts"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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

# --- Fixture: stub cycle, fake curl, isolated config ---------
mkdir -p "$WORK/scripts" "$WORK/bin" "$WORK/locks" "$WORK/logs"
cp "$SCRIPTS/approval_poll.sh" "$WORK/scripts/"

# Stub cycle: records each invocation instead of moving data.
cat > "$WORK/scripts/cold_storage_cycle.sh" <<'EOF'
#!/bin/bash
echo "CYCLE_CALLED $*" >> "${CYCLE_LOG:?}"
EOF

# Fake curl: records the stdin config (which carries the topic
# URL, passed via -K -), then plays back a canned poll response.
cat > "$WORK/bin/curl" <<'EOF'
#!/bin/bash
cat >> "${FAKE_CURL_LOG:?}"
[[ -n "${FAKE_CURL_FAIL:-}" ]] && exit 22
cat "${FAKE_CURL_BODY:-/dev/null}" 2>/dev/null
exit 0
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

export CYCLE_LOG="$WORK/cycle_calls.log"
export FAKE_CURL_LOG="$WORK/curl_calls.log"
export CONFIG_FILE="$WORK/config.env"
touch "$CONFIG_FILE"
export LOG_DIR="$WORK/logs"
export LOCK_DIR="$WORK/locks"
TOKEN="test-approve-token"

cycle_calls() { grep -c CYCLE_CALLED "$CYCLE_LOG" 2>/dev/null || echo 0; }
run_poller() { bash "$WORK/scripts/approval_poll.sh"; }

echo "=== approval_poll.sh ==="

# --- 1. Disarmed by default ----------------------------------
run_poller; rc=$?
check "disarmed poller exits 0" test "$rc" -eq 0
check "disarmed poller never polls" test ! -s "$FAKE_CURL_LOG"
check "disarmed poller never runs the cycle" test "$(cycle_calls)" = 0

# --- 2. Armed but incomplete ---------------------------------
REMOTE_APPROVE=true run_poller 2>/dev/null; rc=$?
check "armed without url/token exits non-zero" test "$rc" -ne 0
check "incomplete config never runs the cycle" test "$(cycle_calls)" = 0

# --- 3. Writable config refused ------------------------------
chmod 666 "$CONFIG_FILE"
OUT=$(REMOTE_APPROVE=true APPROVE_URL="https://ntfy.example/ok" \
      APPROVE_TOKEN="$TOKEN" run_poller 2>&1); rc=$?
check "group-writable config.env is refused" test "$rc" -ne 0
check "refusal names the fix" grep -q "chmod 600" <<< "$OUT"
chmod 600 "$CONFIG_FILE"

# --- 4. Token matching ---------------------------------------
export REMOTE_APPROVE=true
export APPROVE_URL="https://ntfy.example/approve-topic"
export APPROVE_TOKEN="$TOKEN"

cat > "$WORK/poll_body.json" <<EOF
{"id":"m1","time":100,"event":"open","topic":"t"}
{"id":"m2","time":101,"event":"message","topic":"t","message":"not the token"}
EOF
FAKE_CURL_BODY="$WORK/poll_body.json" run_poller
check "wrong token never runs the cycle" test "$(cycle_calls)" = 0
check "state still advances past bad messages" \
    test "$(cat "$LOCK_DIR/approval_poll.since")" = "m2"
check "ignored message is logged" grep -q "ignored 1 non-matching" "$LOG_DIR"/approval_poll_*.log

cat > "$WORK/poll_body.json" <<EOF
{"id":"m3","time":102,"event":"message","topic":"t","message":"$TOKEN"}
EOF
FAKE_CURL_BODY="$WORK/poll_body.json" run_poller
check "matching token runs the cycle once" test "$(cycle_calls)" = 1
check "cycle is invoked with --run" grep -q -- "CYCLE_CALLED --run" "$CYCLE_LOG"
check "state advances to the approval" \
    test "$(cat "$LOCK_DIR/approval_poll.since")" = "m3"

# --- 5. Replay-proof -----------------------------------------
: > "$FAKE_CURL_LOG"
FAKE_CURL_BODY="$WORK/empty.json" run_poller
check "empty poll runs nothing" test "$(cycle_calls)" = 1
check "next poll resumes after the last id" grep -q "since=m3" "$FAKE_CURL_LOG"
check "topic url stays off argv (reaches curl via stdin config)" \
    grep -q 'url = "https://ntfy.example/approve-topic' "$FAKE_CURL_LOG"

# --- 6. Poll failure is soft ---------------------------------
FAKE_CURL_FAIL=1 run_poller; rc=$?
check "unreachable topic exits 0 (retry next cron)" test "$rc" -eq 0
check "poll failure never runs the cycle" test "$(cycle_calls)" = 1

echo ""
echo "approval tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
