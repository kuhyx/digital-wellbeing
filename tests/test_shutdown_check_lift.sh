#!/bin/bash
# Regression tests for the check script's lift branch.
#
# The bug this guards: night lockdown was entered by the per-minute check but
# only ever lifted by the 05:00 unlock ladder. A workout credited at 20:30
# moved /etc/shutdown-schedule.conf to 22:00 and the desktop stayed down
# anyway (2026-09-16). Lockdown is derived from the config in BOTH directions
# now: a tick outside the window (or under an override) that finds the state
# token LOCKED runs the unlock script.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
CHECK_SRC="$REPO_DIR/lib/payloads/day-specific-shutdown-check.sh.in"

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

# Build a runnable copy of the payload with every /etc, /var and /usr/local
# path redirected into the sandbox, so it runs as a non-root user against
# stub enter/unlock scripts that only record that they were called.
CHECK="$TMP_DIR/check.sh"
sed -e "s#^CONFIG_FILE=.*#CONFIG_FILE=\"$TMP_DIR/schedule.conf\"#" \
	-e "s#^OVERRIDES_FILE=.*#OVERRIDES_FILE=\"$TMP_DIR/overrides.conf\"#" \
	-e "s#^LOCKDOWN_STATE_FILE=.*#LOCKDOWN_STATE_FILE=\"$TMP_DIR/state\"#" \
	-e "s#^UNLOCK_SCRIPT=.*#UNLOCK_SCRIPT=\"$TMP_DIR/unlock.sh\"#" \
	-e "s#/usr/local/bin/night-lockdown-enter.sh#$TMP_DIR/enter.sh#g" \
	"$CHECK_SRC" >"$CHECK"
chmod +x "$CHECK"
printf '#!/bin/bash\necho enter >>"%s"\n' "$TMP_DIR/calls" >"$TMP_DIR/enter.sh"
printf '#!/bin/bash\necho unlock >>"%s"\n' "$TMP_DIR/calls" >"$TMP_DIR/unlock.sh"
chmod +x "$TMP_DIR/enter.sh" "$TMP_DIR/unlock.sh"
mkdir -p "$TMP_DIR/bin"
printf '#!/bin/bash\nexit 0\n' >"$TMP_DIR/bin/logger"
chmod +x "$TMP_DIR/bin/logger"
export PATH="$TMP_DIR/bin:$PATH"

# The script reads the wall clock, so the window is placed around "now"
# instead of faking time: hour 0 with morning-end 0 is always inside
# (now >= 00:00), hour 24 with morning-end 0 is never inside.
write_config() {
	printf 'MON_WED_HOUR=%s\nTHU_SUN_HOUR=%s\nMORNING_END_HOUR=0\n' "$1" "$1" >"$TMP_DIR/schedule.conf"
}
run_check() {
	: >"$TMP_DIR/calls"
	rm -f "$TMP_DIR/overrides.conf"
	printf '%s\n' "$1" >"$TMP_DIR/state"
	write_config "$2"
	bash "$CHECK" >/dev/null 2>&1 || fail "check script exited non-zero (state=$1 hour=$2)"
}
calls() { tr '\n' ' ' <"$TMP_DIR/calls"; }

echo "test_shutdown_check_lift.sh"

run_check LOCKED 0
[[ "$(calls)" == "enter " ]] || fail "inside window + LOCKED should re-enter, got: $(calls)"
ok "inside the window a LOCKED machine is re-entered (enforcement gate unchanged)"

run_check UNLOCKED 0
[[ "$(calls)" == "enter " ]] || fail "inside window + UNLOCKED should enter, got: $(calls)"
ok "inside the window an UNLOCKED machine is locked"

run_check LOCKED 24
[[ "$(calls)" == "unlock " ]] || fail "outside window + LOCKED should lift, got: $(calls)"
ok "outside the window a LOCKED machine is lifted (config moved past now)"

run_check UNLOCKED 24
[[ -z "$(calls)" ]] || fail "outside window + UNLOCKED should do nothing, got: $(calls)"
ok "outside the window an UNLOCKED machine is left alone"

rm -f "$TMP_DIR/state"
: >"$TMP_DIR/calls"
write_config 24
bash "$CHECK" >/dev/null 2>&1 || fail "check script failed with no state file"
[[ -z "$(calls)" ]] || fail "missing state file should read as UNLOCKED, got: $(calls)"
ok "a missing state token reads as UNLOCKED (fresh install never runs unlock)"

# An override that is active right now, while still LOCKED: skip the
# enforcement AND lift, since the override is exactly a "not in the window".
run_check LOCKED 0
: >"$TMP_DIR/calls"
printf -v now '%(%s)T' -1
printf '%s|%s|%s|test\n' "$((now - 60))" "$((now + 3600))" "$now" >"$TMP_DIR/overrides.conf"
bash "$CHECK" >/dev/null 2>&1 || fail "check script failed under an override"
[[ "$(calls)" == "unlock " ]] || fail "active override + LOCKED should lift, got: $(calls)"
ok "an active override lifts a LOCKED machine instead of only skipping the lock"

# DRY_RUN must reach the stub with DRY_RUN set, never lift for real.
run_check LOCKED 24
cat >"$TMP_DIR/unlock.sh" <<STUB
#!/bin/bash
echo "unlock dry=\${DRY_RUN:-}" >>"$TMP_DIR/calls"
STUB
: >"$TMP_DIR/calls"
DRY_RUN=1 bash "$CHECK" >/dev/null 2>&1 || fail "DRY_RUN check failed"
[[ "$(calls)" == "unlock dry=1 " ]] || fail "DRY_RUN should pass through to the unlock, got: $(calls)"
ok "DRY_RUN passes through to the unlock script"

# The installed copy must be what the installer writes: the payload verbatim.
# `install` is shadowed so the real function can run without root; only its
# destination is redirected.
INSTALLED="$TMP_DIR/installed.sh"
(
	install() { command install "${@:1:$#-1}" "$INSTALLED"; }
	# shellcheck source=../lib/ms_scripts.sh
	source "$REPO_DIR/lib/ms_scripts.sh"
	create_shutdown_check_script
) >/dev/null
cmp -s "$CHECK_SRC" "$INSTALLED" || fail "installer output differs from the payload"
[[ -x "$INSTALLED" ]] || fail "installer output is not executable"
ok "installer writes the payload byte-for-byte, executable"

printf 'All %d checks passed.\n' "$passed"
