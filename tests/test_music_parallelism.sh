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

# Mirror the script's real position inside the worktree instead of hardcoding
# it. music_parallelism.sh sources its library as $SCRIPT_DIR/../../lib/common.sh,
# so the copy must sit at the same depth below the repo root or that path
# resolves outside the worktree. When it did, the script silently fell back to
# the real /usr/local/lib/common.sh and the stub below was never used — the
# tests then measured the live system and failed as if the daemon were wrong.
# Deriving the path keeps this correct across future reorganisations.
TARGET_REL="${TARGET_SCRIPT#"$REPO_DIR"/}"
if [[ "$TARGET_REL" == "$TARGET_SCRIPT" ]]; then
  fail "TARGET_SCRIPT ($TARGET_SCRIPT) is not below REPO_DIR ($REPO_DIR)"
fi
WORKTREE_SCRIPT="$WORKTREE/$TARGET_REL"
# The library lives at <repo>/scripts/lib/common.sh; keep it relative to the
# same root rather than assuming how deep the script itself is nested.
WORKTREE_LIB="$WORKTREE/scripts/lib/common.sh"

mkdir -p "$(dirname "$WORKTREE_SCRIPT")" "$(dirname "$WORKTREE_LIB")" "$BIN_DIR"
cp "$TARGET_SCRIPT" "$WORKTREE_SCRIPT"

# Fail loudly if the copy cannot reach the stub, rather than letting the script
# fall through to the real library and produce a misleading behavioural failure.
STUB_FROM_SCRIPT="$(dirname "$WORKTREE_SCRIPT")/../../lib/common.sh"
if [[ "$(realpath -m "$STUB_FROM_SCRIPT")" != "$(realpath -m "$WORKTREE_LIB")" ]]; then
  fail "worktree layout drift: script at $WORKTREE_SCRIPT resolves ../../lib/common.sh to $(realpath -m "$STUB_FROM_SCRIPT"), not the stub at $WORKTREE_LIB"
fi

cat >"$WORKTREE_LIB" <<'EOF'
#!/bin/bash

# Records that the stub — not the real installed common.sh — was sourced.
if [[ -n ${MUSIC_PARALLELISM_STUB_MARKER:-} ]]; then
  printf 'sourced\n' >"$MUSIC_PARALLELISM_STUB_MARKER"
fi

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
chmod +x "$WORKTREE_LIB"

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
  local stub_marker="$TMP_DIR/stub.marker"

  : >"$wait_log"
  rm -f "$stub_marker"
  rm -rf "$proc_root"
  mkdir -p "$proc_root"

  if [[ -n $music_proc_name ]]; then
    create_fake_proc_process "$proc_root" 4242 "$music_proc_name"
  fi

  PATH="$BIN_DIR:$PATH" \
    MUSIC_PARALLELISM_TEST_WAIT_LOG="$wait_log" \
    MUSIC_PARALLELISM_TEST_EXIT_AFTER_WAIT=1 \
    MUSIC_PARALLELISM_STUB_MARKER="$stub_marker" \
    XDOTOOL_LOG="${XDOTOOL_LOG:-}" \
    PROC_ROOT="$proc_root" \
    MOCK_FOCUS_ACTIVE="$focus_active" \
    bash "$WORKTREE_SCRIPT" "$mode" \
    >/dev/null 2>&1 || true

  # Without this the script can source the real /usr/local/lib/common.sh and
  # still "pass" or fail for reasons that have nothing to do with the daemon.
  [[ -f "$stub_marker" ]] \
    || fail 'stubbed common.sh was not sourced — the script used a different library, so this run measured the live system rather than the mock'

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
