#!/bin/bash
# Regression tests for the shutdown timer + service units.
#
# The bug this guards: the timer used to carry a copy of the schedule. First it
# was generated from the SCHEDULE_* constants while the check script read
# /etc/shutdown-schedule.conf (config said 23:00, timer started at 00:00, and
# 23:00-00:00 was unenforced every night). Then it was generated from the live
# config at install time, and screen_locker's sick-day feature rewrote the
# config to 20:00 under a timer whose earliest entry was still 23:00
# (2026-09-13). The timer now fires every minute all day and the check script
# alone decides, so there is no copy left to drift.
#
# Second bug: the service had TimeoutStartSec=0 (= infinity). When the lock
# action hung inside openrgb (2026-09-12) the oneshot sat in "activating" all
# night and every later timer tick was a no-op against a live desktop.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

passed=0
fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}
ok() {
	printf '  OK: %s\n' "$1"
	passed=$((passed + 1))
}

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Redirect the hardcoded unit paths so generation can be inspected as a
# non-root user.
UNITS_LIB="$TMP_DIR/ms_units.sh"
GEN_TIMER="$TMP_DIR/gen.timer"
GEN_SERVICE="$TMP_DIR/gen.service"
sed -e "s#/etc/systemd/system/day-specific-shutdown.timer#$GEN_TIMER#" \
	-e "s#/etc/systemd/system/day-specific-shutdown.service#$GEN_SERVICE#" \
	"$REPO_DIR/lib/ms_units.sh" >"$UNITS_LIB"

# Generate the units for the given live-config hours. The SCHEDULE_* constants
# are deliberately set to a DIFFERENT value than the config, which is exactly
# the desync that went unnoticed; neither may leak into the timer now.
gen() {
	local mon_wed="$1" thu_sun="$2" morning_end="$3"
	printf 'MON_WED_HOUR=%s\nTHU_SUN_HOUR=%s\nMORNING_END_HOUR=%s\n' \
		"$mon_wed" "$thu_sun" "$morning_end" >"$TMP_DIR/sched.conf"
	(
		export SCHEDULE_MON_WED_HOUR=21
		export SCHEDULE_THU_SUN_HOUR=21
		export SCHEDULE_MORNING_END_HOUR=5
		export CONFIG_FILE="$TMP_DIR/sched.conf"
		# shellcheck source=/dev/null
		source "$UNITS_LIB"
		create_shutdown_timer >/dev/null
		create_shutdown_service >/dev/null
	)
	grep '^OnCalendar=' "$GEN_TIMER"
}

printf '\nthe timer fires every minute of every hour, whatever the config says\n'
for cfg in "23 23 5" "20 20 5" "24 24 5" "18 21 7"; do
	# shellcheck disable=SC2086 # three space-separated ints by construction
	out="$(gen $cfg)"
	[[ "$out" == 'OnCalendar=*-*-* *:*:00' ]] ||
		fail "config '$cfg' must produce exactly one all-day per-minute entry, got: $out"
done
ok "one all-day per-minute entry for every schedule"
grep -q '21' "$GEN_TIMER" &&
	fail "the SCHEDULE_* constant must not leak into the unit"
ok "no schedule value is copied into the timer"

printf '\nthe service is bounded, never TimeoutStartSec=0\n'
grep -q '^TimeoutStartSec=0$' "$GEN_SERVICE" &&
	fail "TimeoutStartSec=0 is infinity: a hung lock action blocks every later tick"
ok "no infinite start timeout"
timeout_s="$(sed -n 's/^TimeoutStartSec=\([0-9]\+\)$/\1/p' "$GEN_SERVICE")"
[[ -n "$timeout_s" && "$timeout_s" -ge 30 && "$timeout_s" -le 600 ]] ||
	fail "TimeoutStartSec must be a bounded number of seconds, got '${timeout_s:-unset}'"
ok "TimeoutStartSec=$timeout_s"

printf '\nthe per-minute tick does not flood the journal\n'
grep -q '^LogLevelMax=notice$' "$GEN_SERVICE" ||
	fail "LogLevelMax=notice is what silences PID 1's per-minute Starting/Finished lines"
ok "PID 1 chatter is capped"
grep -q '^SyslogLevel=notice$' "$GEN_SERVICE" ||
	fail "SyslogLevel=notice keeps the scripts' own stdout above the cap"
ok "script output survives the cap"

printf '\nthe check script is silent outside the window\n'
CHECK_SRC="$REPO_DIR/lib/ms_scripts.sh"
grep -q 'Checking shutdown conditions' "$CHECK_SRC" &&
	fail "an unconditional per-run log line is 1440 journal lines a day"
ok "no unconditional per-run log line"
grep -q 'Skipped shutdown - not within' "$CHECK_SRC" &&
	fail "the out-of-window branch must not log via logger"
ok "the out-of-window branch is silent"

printf '\ntest_shutdown_timer_schedule: %d passed, 0 failed\n' "$passed"
