#!/bin/bash
# Regression tests for the minute-precision shutdown schedule.
#
# /etc/shutdown-schedule.conf carries *_MINUTES keys (minutes after midnight,
# authoritative) beside strict-rounded legacy *_HOUR keys. The check script
# must prefer the minutes, fall back to HOUR*60 for a pre-migration file, and
# refuse a value it cannot place on the clock instead of guessing. Before the
# migration a 30-minute earner could not be expressed at all.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
CHECK_SRC="$REPO_DIR/lib/payloads/day-specific-shutdown-check.sh"

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

# Same sandboxed copy as test_shutdown_check_lift.sh: every root path points
# into TMP_DIR and the enter/unlock scripts only record that they ran.
CHECK="$TMP_DIR/check.sh"
sed -e "s#^CONFIG_FILE=.*#CONFIG_FILE=\"$TMP_DIR/schedule.conf\"#" \
	-e "s#^OVERRIDES_FILE=.*#OVERRIDES_FILE=\"$TMP_DIR/overrides.conf\"#" \
	-e "s#^LOCKDOWN_STATE_FILE=.*#LOCKDOWN_STATE_FILE=\"$TMP_DIR/state\"#" \
	-e "s#^UNLOCK_SCRIPT=.*#UNLOCK_SCRIPT=\"$TMP_DIR/unlock.sh\"#" \
	-e "s#/usr/local/bin/night-lockdown-enter.sh#$TMP_DIR/enter.sh#g" \
	"$CHECK_SRC" >"$CHECK"
printf '#!/bin/bash\necho enter >>"%s"\n' "$TMP_DIR/calls" >"$TMP_DIR/enter.sh"
printf '#!/bin/bash\necho unlock >>"%s"\n' "$TMP_DIR/calls" >"$TMP_DIR/unlock.sh"
chmod +x "$TMP_DIR/enter.sh" "$TMP_DIR/unlock.sh"
mkdir -p "$TMP_DIR/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$TMP_DIR/journal" >"$TMP_DIR/bin/logger"
chmod +x "$TMP_DIR/bin/logger"
export PATH="$TMP_DIR/bin:$PATH"

# The script reads the wall clock, so windows are placed around "now" rather
# than faking time. A shutdown at now+1 minute is not yet due; one at now is.
printf -v hour '%(%H)T' -1
printf -v minute '%(%M)T' -1
now=$((10#$hour * 60 + 10#$minute))
if [[ $now -ge 1439 ]]; then
	echo "SKIP: too close to midnight for a now+1 window" >&2
	exit 0
fi

# Writes the config body and runs one tick; prints the stub calls.
tick() {
	printf '%b' "$1" >"$TMP_DIR/schedule.conf"
	: >"$TMP_DIR/calls"
	: >"$TMP_DIR/journal"
	echo UNLOCKED >"$TMP_DIR/state"
	bash "$CHECK" >/dev/null 2>&1 && rc=0 || rc=$?
	printf '%s|%s' "$rc" "$(tr '\n' ' ' <"$TMP_DIR/calls")"
}

echo "test_shutdown_check_minutes.sh"

result=$(tick "MON_WED_MINUTES=$now\nTHU_SUN_MINUTES=$now\nMORNING_END_MINUTES=0\n")
[[ $result == "0|enter " ]] || fail "minutes-only config at now should lock, got: $result"
ok "a minutes-only config locks once its minute arrives"

result=$(tick "MON_WED_MINUTES=$((now + 1))\nTHU_SUN_MINUTES=$((now + 1))\nMORNING_END_MINUTES=0\n")
[[ $result == "0|" ]] || fail "minutes-only config at now+1 should not lock, got: $result"
ok "one minute before the shutdown minute stays open"

# The legacy hour 0 alone would mean "inside the window all day"; the minutes
# key must win over it.
result=$(tick "MON_WED_MINUTES=$((now + 1))\nTHU_SUN_MINUTES=$((now + 1))\nMORNING_END_MINUTES=0\nMON_WED_HOUR=0\nTHU_SUN_HOUR=0\nMORNING_END_HOUR=0\n")
[[ $result == "0|" ]] || fail "*_MINUTES must take precedence over *_HOUR, got: $result"
ok "*_MINUTES takes precedence over the legacy *_HOUR keys"

result=$(tick "MON_WED_HOUR=0\nTHU_SUN_HOUR=0\nMORNING_END_HOUR=0\n")
[[ $result == "0|enter " ]] || fail "legacy hour-only config should still lock, got: $result"
result=$(tick "MON_WED_HOUR=24\nTHU_SUN_HOUR=24\nMORNING_END_HOUR=0\n")
[[ $result == "0|" ]] || fail "legacy 24 (midnight) should not lock before midnight, got: $result"
ok "a pre-migration hour-only config is read as HOUR * 60"

result=$(tick "MON_WED_MINUTES=1441\nTHU_SUN_MINUTES=1441\nMORNING_END_MINUTES=0\n")
[[ $result == "1|" ]] || fail "1441 minutes should be refused, got: $result"
grep -q "not 0-1440 minutes" "$TMP_DIR/journal" || fail "an out-of-range value must be logged"
result=$(tick "MON_WED_MINUTES=18:30\nTHU_SUN_MINUTES=1110\nMORNING_END_MINUTES=300\n")
[[ $result == "1|" ]] || fail "a non-integer minutes value should be refused, got: $result"
ok "an out-of-range or non-integer value is refused and logged, never guessed"

result=$(tick "MORNING_END_MINUTES=300\n")
[[ $result == "1|" ]] || fail "a config missing the evening values should be refused, got: $result"
ok "a config missing a value in both forms is refused"

# The journal line names the window in HH:MM, minutes included.
tick "MON_WED_MINUTES=$now\nTHU_SUN_MINUTES=$now\nMORNING_END_MINUTES=330\n" >/dev/null
printf -v want '%02d:%02d-05:30' $((now / 60)) $((now % 60))
grep -q "inside the $want shutdown window" "$TMP_DIR/journal" ||
	fail "journal should name the $want window, got: $(cat "$TMP_DIR/journal")"
ok "the journal names the window as HH:MM-HH:MM"

printf 'All %d checks passed.\n' "$passed"
