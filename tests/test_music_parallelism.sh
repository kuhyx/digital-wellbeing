#!/bin/bash
# Regression tests for the music parallelism daemon's polling cadence.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TARGET_SCRIPT="$REPO_DIR/scripts/periodic_background/digital_wellbeing/music_parallelism.sh"

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
mkdir -p "$WORKTREE/scripts/periodic_background/digital_wellbeing" "$WORKTREE/scripts/lib" "$BIN_DIR"
cp "$TARGET_SCRIPT" "$WORKTREE/scripts/periodic_background/digital_wellbeing/music_parallelism.sh"

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

create_fake_proc_process() {
  local proc_root="$1"
  local pid="$2"
  local name="$3"
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$name" >"$proc_root/$pid/comm"
}

run_case() {
  local expected_wait="$1"
  local focus_active="$2"
  local music_proc_name="${3:-}"
  local mode="${4:-instant}"
  local wait_log="$TMP_DIR/wait.log"
  local proc_root="$TMP_DIR/proc"

  : >"$wait_log"
  rm -rf "$proc_root"
  mkdir -p "$proc_root"

  if [[ -n $music_proc_name ]]; then
    create_fake_proc_process "$proc_root" 4242 "$music_proc_name"
  fi

  PATH="$BIN_DIR:$PATH" \
    MUSIC_PARALLELISM_TEST_WAIT_LOG="$wait_log" \
    MUSIC_PARALLELISM_TEST_EXIT_AFTER_WAIT=1 \
    XDOTOOL_LOG="${XDOTOOL_LOG:-}" \
    PROC_ROOT="$proc_root" \
    MOCK_FOCUS_ACTIVE="$focus_active" \
    bash "$WORKTREE/scripts/periodic_background/digital_wellbeing/music_parallelism.sh" "$mode" \
    >/dev/null 2>&1 || true

  assert_equals "$expected_wait" "$(<"$wait_log")" "music_parallelism.sh should pick the expected wait interval"
}

printf 'Checking stable-focus backoff uses the slower interval...\n'
run_case 15 1

printf 'Checking conflict handling uses the faster retry interval...\n'
run_case 5 1 spotify

printf 'Checking idle mode uses the idle interval...\n'
run_case 30 0

printf 'Checking conflict path avoids duplicate xdotool searches...\n'
xdotool_log="$TMP_DIR/xdotool.log"
: >"$xdotool_log"
XDOTOOL_LOG="$xdotool_log"

cat >"$BIN_DIR/xdotool" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "${XDOTOOL_LOG:?}"
if [[ ${1:-} == search ]]; then
  exit 1
fi
if [[ ${1:-} == windowclose ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "$BIN_DIR/xdotool"

run_case 5 1 spotify

search_calls=$(grep -c '^search$' "$xdotool_log" 2>/dev/null || true)
assert_equals '1' "$search_calls" 'music_parallelism.sh should avoid duplicate xdotool search calls when process-only music is detected'

printf 'Checking monitor loop also avoids duplicate xdotool searches...\n'
: >"$xdotool_log"
run_case 15 1 spotify monitor
monitor_search_calls=$(grep -c '^search$' "$xdotool_log" 2>/dev/null || true)
assert_equals '1' "$monitor_search_calls" 'music_parallelism.sh monitor loop should avoid duplicate xdotool search calls when process-only music is detected'

printf 'music_parallelism.sh regression checks passed.\n'
