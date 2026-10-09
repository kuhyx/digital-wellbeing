#!/usr/bin/env bash
# Covers lib/cco_wrapper.sh — the launch path the /usr/bin/<app> shims exec into.
#
# Safe to run here despite the harness's "never exec an app" rule: the real
# binary is a fake under TEST_TMPDIR, and each wrapper_main call runs in a
# subshell, so its exec replaces that subshell and nothing else.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cco_harness.sh
. "$HERE/cco_harness.sh"
# shellcheck source=../cco_state.sh
. "$CCO_LIB_DIR/cco_state.sh"
# shellcheck source=../cco_wrapper.sh
. "$CCO_LIB_DIR/cco_wrapper.sh"

_t_cco_setup
trap _t_cco_teardown EXIT

# A fake app that records how it was started. If it reports the subshell's own
# PID, the wrapper exec'd into it rather than forking and supervising it.
ran="$TEST_TMPDIR/ran"
cat >"$TEST_TMPDIR/real/beepertexts" <<EOF
#!/bin/bash
printf '%s %s\n' "\$\$" "\$*" >"$ran"
EOF
chmod +x "$TEST_TMPDIR/real/beepertexts"
: >"$TEST_TMPDIR/bin/beeper.orig"

printf 'wrapper_main: an unwrapped app is refused\n'
if (wrapper_main signal-desktop) 2>/dev/null; then
	_t_fail "a missing real binary exits non-zero"
else
	_t_pass "a missing real binary exits non-zero"
fi

printf '\nwrapper_main: the first launch this hour execs the real binary\n'
rm -f "$ran" "$STATE_DIR/beeper.lastopen"
pid="$(
	wrapper_main beeper --flag value 2>/dev/null &
	echo "$!"
	wait
)"
_t_eq "$pid --flag value" "$(cat "$ran")" "the app replaces the wrapper process and gets its arguments"
_t_has "$(cat "$LOG_FILE")" "LAUNCHED: beeper" "the launch is logged"
_t_eq "$(get_hour_key)" "$(cat "$STATE_DIR/beeper.lastopen")" "the launch is recorded for this hour"

printf '\nwrapper_main: no session timer is left behind\n'
# The auto-close daemon was removed on purpose; a launch must leave no state
# or process that could later close the app.
if [[ -e "$STATE_DIR/beeper.running" ]]; then
	_t_fail "no running-state file is written"
else
	_t_pass "no running-state file is written"
fi
_t_eq "" "$(grep -E 'auto-close|AUTO-CLOSED' "$LOG_FILE" || true)" "nothing mentions auto-close"

printf '\nwrapper_main: a second launch in the same hour is blocked\n'
rm -f "$ran"
: >"$TEST_TMPDIR/notifications"
if (wrapper_main beeper) 2>/dev/null; then
	_t_fail "a second launch exits non-zero"
else
	_t_pass "a second launch exits non-zero"
fi
if [[ -e $ran ]]; then
	_t_fail "the blocked launch does not start the app"
else
	_t_pass "the blocked launch does not start the app"
fi
_t_has "$(cat "$TEST_TMPDIR/notifications")" "Blocked" "the block is notified"

_t_report "test_cco_wrapper"
