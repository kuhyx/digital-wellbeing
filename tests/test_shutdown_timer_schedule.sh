#!/bin/bash
# Regression tests for create_shutdown_timer's OnCalendar generation.
#
# The bug this guards: the timer used to be generated from the SCHEDULE_*
# constants in setup_midnight_shutdown.sh, while the check script reads
# /etc/shutdown-schedule.conf. Anything that edits that config in place
# (screen_locker's sick-day feature does) desynced the two. On this machine the
# config said 23:00 while the installed timer's earliest entry was 00:00, so
# 23:00-00:00 was unenforced every night and nothing reported it.

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

# Redirect the hardcoded unit path so generation can be inspected as a
# non-root user.
UNITS_LIB="$TMP_DIR/ms_units.sh"
GEN_TIMER="$TMP_DIR/gen.timer"
sed "s#/etc/systemd/system/day-specific-shutdown.timer#$GEN_TIMER#" \
	"$REPO_DIR/lib/ms_units.sh" >"$UNITS_LIB"

# Generate a timer for the given live-config hours and echo its OnCalendar
# lines. The SCHEDULE_* constants are deliberately set to a DIFFERENT value
# than the config, which is exactly the desync that went unnoticed.
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
	)
	grep '^OnCalendar=' "$GEN_TIMER"
}

printf '\nthe live config wins over the SCHEDULE_* constants\n'
out="$(gen 23 23 5)"
grep -q '^OnCalendar=\*-\*-\* 23:\*:00$' <<<"$out" ||
	fail "a 23:00 config must produce a 23:00 entry (constants say 21)"
ok "a 23:00 config produces a 23:00 entry"
grep -q '^OnCalendar=\*-\*-\* 21:\*:00$' <<<"$out" &&
	fail "the stale 21 constant must not leak into the unit"
ok "the stale constant does not leak in"

printf '\nthe whole window is covered, and nothing outside it\n'
for h in 23 00 01 02 03 04; do
	grep -q "^OnCalendar=\*-\*-\* $h:\*:00\$" <<<"$out" ||
		fail "hour $h is inside the 23:00-05:00 window and must be covered"
done
ok "every hour from 23:00 to 04:59 is covered"
grep -q '^OnCalendar=\*-\*-\* 05:' <<<"$out" &&
	fail "05:00 is outside the window (MORNING_END_HOUR is exclusive)"
ok "05:00 is not covered"
grep -q '^OnCalendar=\*-\*-\* 22:' <<<"$out" &&
	fail "22:00 is before the shutdown hour and must not fire"
ok "22:00 is not covered"

printf '\ngranularity is per-minute, not per-half-hour\n'
grep -q '^OnCalendar=\*-\*-\* 00:30:00$' <<<"$out" &&
	fail "the :00/:30 pair left 30 usable minutes after any lapse in enforcement"
ok "no half-hourly entries remain"
[[ "$(grep -c ':\*:00$' <<<"$out")" == "$(wc -l <<<"$out")" ]] ||
	fail "every entry should use the per-minute HH:*:00 form"
ok "every entry uses the per-minute form"

printf '\nthe earliest of the two day-group hours wins\n'
out="$(gen 21 23 5)"
grep -q '^OnCalendar=\*-\*-\* 21:\*:00$' <<<"$out" ||
	fail "Mon-Wed 21:00 is earlier than Thu-Sun 23:00 and must be covered"
ok "the earlier of the two hours starts the window"

printf '\nan hour of 24 means midnight, i.e. no evening entries\n'
out="$(gen 24 24 5)"
grep -q '^OnCalendar=\*-\*-\* 2[0-3]:' <<<"$out" &&
	fail "a 24:00 schedule must not produce evening entries"
ok "a 24:00 schedule produces no evening entries"
grep -q '^OnCalendar=\*-\*-\* 00:\*:00$' <<<"$out" ||
	fail "a 24:00 schedule still covers the morning half of the window"
ok "it still covers the morning half"

printf '\ntest_shutdown_timer_schedule: %d passed, 0 failed\n' "$passed"
