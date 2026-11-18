#!/bin/bash
# Regression tests for shutdown-timer-monitor.sh dispatcher behavior.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shutdown-timer-monitor.sh moved to github.com/kuhyx/system-maintenance with
# the rest of that subsystem, but this suite is the pair test: it checks that
# digital_wellbeing's installer and the monitor it installs still agree. Prefer
# a sibling checkout, fall back to the installed copy, and skip rather than
# fail when neither is present -- a missing checkout is not a regression.
TARGET_SCRIPT="${SYSTEM_MAINTENANCE_DIR:-$HOME/src/system-maintenance}/bin/shutdown-timer-monitor.sh"
# Deliberately NOT falling back to /usr/local/bin: the installed copy can be
# older than the source (it is, on this machine), and testing the installer
# template against a stale binary compares two things that were never meant to
# match. Skip instead -- a missing checkout is not a regression.
if [[ ! -f $TARGET_SCRIPT ]]; then
	printf 'SKIP: shutdown-timer-monitor.sh not found (set SYSTEM_MAINTENANCE_DIR)\n'
	exit 0
fi
SETUP_SCRIPT="$REPO_DIR/setup_midnight_shutdown.sh"
# The installer was split into lib/ms_*.sh under the 250-line cap, so these
# template checks search the entry script AND its libs: the monitor template
# now lives in lib/ms_monitor.sh, it did not disappear.
SETUP_SOURCES=("$SETUP_SCRIPT")
for _ms_lib in "$(dirname "$SETUP_SCRIPT")"/lib/ms_*.sh; do
	[[ -f "$_ms_lib" ]] && SETUP_SOURCES+=("$_ms_lib")
done

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
mkdir -p "$WORKTREE/system-maintenance/bin" "$BIN_DIR"
cp "$TARGET_SCRIPT" "$WORKTREE/system-maintenance/bin/shutdown-timer-monitor.sh"

cat >"$BIN_DIR/busctl" <<'EOF'
#!/bin/bash
if [[ $1 == monitor ]]; then
  payload=${MOCK_BUSCTL_LINES:-${MOCK_BUSCTL_LINE:-no relevant event}}
  printf '%b\n' "$payload" | while read -r line; do
    printf '%s\n' "$line"
  done
  exit 0
fi

printf 'unexpected busctl args: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$BIN_DIR/busctl"

cat >"$BIN_DIR/systemctl" <<'EOF'
#!/bin/bash
case "$*" in
  'is-enabled day-specific-shutdown.timer'|'is-active day-specific-shutdown.timer')
    exit 0
    ;;
  'daemon-reload'|'enable day-specific-shutdown.timer'|'start day-specific-shutdown.timer')
    exit 0
    ;;
  *)
    printf 'unexpected systemctl args: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$BIN_DIR/systemctl"

cat >"$BIN_DIR/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "${SLEEP_LOG:?}"
exit 99
EOF
chmod +x "$BIN_DIR/sleep"

cat >"$BIN_DIR/tee" <<'EOF'
#!/bin/bash
while IFS= read -r _; do
  :
done
EOF
chmod +x "$BIN_DIR/tee"

run_case() {
	local expected_mode="$1"
	local busctl_present="$2"
	local sleep_log="$TMP_DIR/sleep.log"
	local mode_file="$TMP_DIR/mode.log"

	: >"$sleep_log"
	: >"$mode_file"
	if [[ $busctl_present -eq 0 ]]; then
		mv "$BIN_DIR/busctl" "$BIN_DIR/busctl.off"
	fi

	mode=$(env -i PATH="$BIN_DIR" SLEEP_LOG="$sleep_log" SHUTDOWN_TIMER_MONITOR_SKIP_MAIN=1 /bin/bash -c \
		"source '$WORKTREE/system-maintenance/bin/shutdown-timer-monitor.sh'; \
     timer_needs_restoration() { return 1; }; \
     restore_timer() { :; }; \
     monitor_with_polling() { printf 'polling'; }; \
     start_monitoring")

	assert_equals "$expected_mode" "$mode" 'shutdown timer monitor should choose the expected dispatcher'

	if [[ -f "$BIN_DIR/busctl.off" ]]; then
		mv "$BIN_DIR/busctl.off" "$BIN_DIR/busctl"
	fi
}

# Poll only since 2026-10-24: a root `busctl monitor | while read` loop filled
# dbus-broker's shared quota and got PID1 and logind disconnected, which killed
# the X session. busctl being installed must not bring it back.
printf 'Checking the monitor polls even when busctl exists...\n'
run_case polling 1

printf 'Checking the monitor polls when busctl is absent...\n'
run_case polling 0

printf 'Checking wait helper enforces delay even with /dev/null stdin...\n'
wait_elapsed=$(env -i PATH="/usr/bin:/bin" SHUTDOWN_TIMER_MONITOR_SKIP_MAIN=1 /bin/bash -c \
	"source '$WORKTREE/system-maintenance/bin/shutdown-timer-monitor.sh'; \
   start=\$(printf '%(%s)T' -1); \
   wait_seconds 1; \
   end=\$(printf '%(%s)T' -1); \
   printf '%s' \$((end-start))" </dev/null)
assert_equals '1' "$wait_elapsed" 'wait_seconds should not return immediately on /dev/null stdin'

printf 'Checking installer template stays in sync with the poll-only monitor...\n'
grep -Fq 'start_monitoring()' "${SETUP_SOURCES[@]}" ||
	fail 'setup_midnight_shutdown.sh should install the start_monitoring dispatcher'
for src in "${SETUP_SOURCES[@]}" "$TARGET_SCRIPT"; do
	# Code lines only: both files keep a comment that names the old loop.
	if grep -Ev '^[[:space:]]*#' "$src" | grep -Eq 'busctl monitor|monitor_with_dbus'; then
		fail "$src must not run a busctl monitor (dbus-broker quota, 2026-10-24)"
	fi
done
grep -Fq 'OnUnitActiveSec=300' "${SETUP_SOURCES[@]}" ||
	fail 'setup_midnight_shutdown.sh should run watchdog timer at 300s cadence'
grep -Fq 'wait_seconds()' "${SETUP_SOURCES[@]}" ||
	fail 'setup_midnight_shutdown.sh should install builtin wait helper in polling fallback'
# Literal source text, as above.
# shellcheck disable=SC2016
grep -Fq 'wait_seconds "$CHECK_INTERVAL"' "$TARGET_SCRIPT" ||
	fail 'runtime shutdown monitor polling fallback should use builtin wait helper'

printf 'shutdown-timer-monitor.sh regression checks passed.\n'
