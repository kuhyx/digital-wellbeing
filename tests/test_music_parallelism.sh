#!/bin/bash
# Regression tests for the music parallelism daemon's polling cadence.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TARGET_SCRIPT="$REPO_DIR/scripts/digital_wellbeing/music_parallelism.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "$context (expected: '$expected', actual: '$actual')"
  fi
}

TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

WORKTREE="$TMP_DIR/worktree"
BIN_DIR="$TMP_DIR/bin"
mkdir -p "$WORKTREE/scripts/digital_wellbeing" "$WORKTREE/scripts/lib" "$BIN_DIR"
cp "$TARGET_SCRIPT" "$WORKTREE/scripts/digital_wellbeing/music_parallelism.sh"

cat >"$WORKTREE/scripts/lib/common.sh" <<'EOF'
#!/bin/bash

FOCUS_APPS_WINDOWS=("Mock Focus App")
FOCUS_APPS_PROCESSES=("mock-focus-proc")

is_focus_app_running() {
  if [[ ${MOCK_FOCUS_ACTIVE:-0} -eq 1 ]]; then
    printf '%s\n' "Mock Focus App"
    return 0
  fi

  return 1
}

get_timestamp() {
  printf '%s\n' "${MOCK_TIMESTAMP:-1000}"
}

log_message() {
  :
}
EOF
chmod +x "$WORKTREE/scripts/lib/common.sh"

cat >"$BIN_DIR/pgrep" <<'EOF'
#!/bin/bash
if [[ ${MOCK_MUSIC_RUNNING:-0} -eq 1 ]]; then
  exit 0
fi
exit 1
EOF
chmod +x "$BIN_DIR/pgrep"

cat >"$BIN_DIR/pkill" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN_DIR/pkill"

cat >"$BIN_DIR/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "${SLEEP_LOG:?}"
exit 99
EOF
chmod +x "$BIN_DIR/sleep"

run_case() {
  local expected_sleep="$1"
  local focus_active="$2"
  local music_running="$3"
  local sleep_log="$TMP_DIR/sleep.log"

  : >"$sleep_log"
  PATH="$BIN_DIR:$PATH" \
    SLEEP_LOG="$sleep_log" \
    MOCK_FOCUS_ACTIVE="$focus_active" \
    MOCK_MUSIC_RUNNING="$music_running" \
    bash "$WORKTREE/scripts/digital_wellbeing/music_parallelism.sh" instant \
    >/dev/null 2>&1 || true

  assert_equals "$expected_sleep" "$(<"$sleep_log")" "music_parallelism.sh should pick the expected sleep interval"
}

printf 'Checking stable-focus backoff uses the slower interval...\n'
run_case 15 1 0

printf 'Checking conflict handling uses the faster retry interval...\n'
run_case 5 1 1

printf 'Checking idle mode uses the idle interval...\n'
run_case 30 0 0

printf 'music_parallelism.sh regression checks passed.\n'
