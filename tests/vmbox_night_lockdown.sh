#!/bin/bash
# End-to-end night-lockdown test in a disposable VM (~/src/utils/vmbox).
#
# Not a test_*.sh: it boots a guest, needs vmbox and sudo for the read-only
# bind mounts, and takes a few minutes. Run it by hand before touching the
# lock path on the real machine:
#
#   tests/vmbox_night_lockdown.sh            # full run, sandbox 'nl'
#   VMBOX_NL_KEEP=1 tests/vmbox_night_lockdown.sh   # leave the sandbox up
#
# What it proves, from the host, against the real installers and the real
# systemd units, with the guest's login topology switched to the host's
# (lightdm autologin -> i3) and openrgb replaced by a shim that never returns:
#
#   1. the per-minute timer fires the check inside the window
#   2. the lock action finishes (the oneshot goes inactive) despite the hang
#   3. lightdm is masked AND stopped, getty@ is masked, state is LOCKED
#   4. enforcement landed BEFORE openrgb was ever called
#   5. the screen is black
#   6. unlock brings lightdm back and the screen is no longer black
#
# Step 6 runs under a registered override, because the guest is still inside
# the window: a bare unlock there is re-locked by the next per-minute tick,
# which is correct (`setup_night_lockdown.sh unlock` says so) and is NOT what
# this step tests. It tests the 05:00 path, which runs outside the window.
#
# The 2026-09-12 failure (openrgb 1.0-2 hanging before the teardown, the unit
# stuck in "activating" all night) fails step 2 and 3 here.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
GUARD_LIB="${GUARD_LIB_DIR:-$HOME/src/utils/guard-lib}"
VM="${VMBOX_NL_NAME:-nl}"
# Sunday 20:57 -> the default 21:00 Thu-Sun window opens three minutes in.
# The pin is re-applied on every launch (vm lightdm reboots once), so the
# installers below run in that headroom and the first tick lands after them.
RTC="${VMBOX_NL_RTC:-2026-09-13T20:57:00}"

passed=0
fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}
ok() {
	printf '  OK: %s\n' "$1"
	passed=$((passed + 1))
}
# `vm run` prints its own "==> Running in" header and " ok  VERDICT" trailer
# on stdout around the guest's output; strip both so callers see only the
# guest. Colour codes are off because stdout is not a terminal here.
guest() { vm run "$VM" "$@" 2>/dev/null | sed '/^==> Running in/d;/VERDICT:/d;/^$/d'; }
# A guest command whose LAST stdout line is the assertion.
probe() { guest "$1" | tail -1; }

TMP_DIR=$(mktemp -d)
cleanup() {
	[[ "${VMBOX_NL_KEEP:-0}" == 1 ]] || vm rm "$VM" >/dev/null 2>&1 || true
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

command -v vm >/dev/null || fail "vmbox's 'vm' is not on PATH (run ~/src/utils/vmbox/install.sh)"
[[ -d "$GUARD_LIB" ]] || fail "guard-lib not found at $GUARD_LIB"

printf '\n== sandbox: fresh overlay, host login topology, hardware shims\n'
vm share "$REPO_DIR" >/dev/null
vm share "$GUARD_LIB" >/dev/null
vm rm "$VM" >/dev/null 2>&1 || true
vm new "$VM" --rtc "$RTC" >/dev/null
vm run "$VM" true >/dev/null 2>&1
vm repo "$VM" "$REPO_DIR" --worktree >/dev/null
vm repo "$VM" "$GUARD_LIB" --worktree >/dev/null
vm lightdm "$VM" >/dev/null
vm shim "$VM" openrgb hang >/dev/null
vm shim "$VM" nvidia-smi exit >/dev/null
vm shim "$VM" amixer exit >/dev/null
[[ "$(probe 'systemctl is-active lightdm.service')" == active ]] ||
	fail "lightdm is not active in the sandbox before the test"
ok "sandbox up: lightdm active, openrgb shimmed to hang"

printf '\n== install: guard-lib, shutdown fortress, night lockdown\n'
guest "sudo bash ~/guard-lib/install.sh" >/dev/null ||
	fail "guard-lib install failed"
guest "sudo MIDNIGHT_SHUTDOWN_CONFIRM=y bash ~/$(basename "$REPO_DIR")/setup_midnight_shutdown.sh enable" >"$TMP_DIR/ms.log" ||
	fail "setup_midnight_shutdown.sh enable failed: $(tail -5 "$TMP_DIR/ms.log")"
guest "sudo bash ~/$(basename "$REPO_DIR")/setup_night_lockdown.sh setup" >"$TMP_DIR/nl.log" ||
	fail "setup_night_lockdown.sh setup failed: $(tail -5 "$TMP_DIR/nl.log")"
[[ "$(probe 'systemctl is-active day-specific-shutdown.timer')" == active ]] ||
	fail "day-specific-shutdown.timer is not active"
[[ "$(probe 'systemctl show -p TimeoutStartUSec --value day-specific-shutdown.service')" != infinity ]] ||
	fail "day-specific-shutdown.service still has an infinite start timeout"
[[ "$(probe 'grep -c "^OnCalendar=\*-\*-\* \*:\*:00$" /etc/systemd/system/day-specific-shutdown.timer')" == 1 ]] ||
	fail "the installed timer is not the all-day per-minute one"
ok "installed: timer active every minute, service start timeout bounded"

printf '\n== lock: wait for the window to open and the tick to run\n'
# The window opens at 21:00 guest time; the timer fires every minute. Poll the
# state file rather than sleeping a fixed time.
deadline=$((SECONDS + 300))
while (( SECONDS < deadline )); do
	[[ "$(probe 'cat /var/lib/night-lockdown/state 2>/dev/null')" == LOCKED ]] && break
	sleep 5
done
[[ "$(probe 'cat /var/lib/night-lockdown/state')" == LOCKED ]] ||
	fail "state never became LOCKED (timer did not fire or the action died)"
ok "the timer fired and state is LOCKED"

# The oneshot must FINISH: a hang leaves it 'activating' and blocks every
# later tick. Give the cosmetics timeout room, then require inactive.
deadline=$((SECONDS + 200))
while (( SECONDS < deadline )); do
	[[ "$(probe 'systemctl is-active day-specific-shutdown.service')" == inactive ]] && break
	sleep 5
done
[[ "$(probe 'systemctl is-active day-specific-shutdown.service')" == inactive ]] ||
	fail "day-specific-shutdown.service never went inactive with a hung openrgb"
ok "the lock action finished despite the never-returning openrgb"

[[ "$(probe 'systemctl is-enabled lightdm.service')" == masked ]] || fail "lightdm is not masked"
[[ "$(probe 'systemctl is-active lightdm.service')" != active ]] || fail "lightdm is still active"
[[ "$(probe 'systemctl is-enabled getty@.service')" == masked ]] || fail "getty@ is not masked"
ok "lightdm masked + stopped, getty@ masked"

guest "sudo journalctl -t night-lockdown -o short-unix --no-pager" >"$TMP_DIR/journal"
enforced_ts="$(grep 'enforcement in effect' "$TMP_DIR/journal" | head -1 | cut -d' ' -f1 | cut -d. -f1)"
[[ -n "$enforced_ts" ]] || fail "no 'enforcement in effect' line in the guest journal"
rgb_ts="$(probe 'cut -d" " -f1 /var/log/vmbox-shim/openrgb.log | head -1')"
[[ -n "$rgb_ts" ]] || fail "openrgb shim was never called"
[[ "$rgb_ts" -ge "$enforced_ts" ]] ||
	fail "openrgb ran at $rgb_ts, before enforcement at $enforced_ts"
ok "openrgb was only called after enforcement (t=$enforced_ts -> $rgb_ts)"
grep -q 'WARN: command failed (continuing): timeout .*openrgb' "$TMP_DIR/journal" ||
	fail "the hung openrgb was not reported as a WARN"
grep -q 'night lockdown active' "$TMP_DIR/journal" ||
	fail "the enter script did not reach its final line"
ok "the hang is logged and the script ran to the end"

vm screenshot "$VM" "$TMP_DIR/locked.png" >/dev/null
python3 "$SCRIPT_DIR/lib/png_brightness.py" "$TMP_DIR/locked.png" >"$TMP_DIR/locked.mean"
locked_mean="$(cat "$TMP_DIR/locked.mean")"
(( locked_mean < 8 )) || fail "screen is not black after lockdown (mean brightness $locked_mean)"
ok "screen is black (mean brightness $locked_mean)"

printf '\n== unlock: the morning path restores the desktop\n'
# Still inside the window, so the next per-minute tick would re-lock a bare
# unlock (it did, in the first run of this test). Suspend the curfew the way
# the product does — an entry in the overrides file the check script reads —
# written directly, because shutdown-override-manager.sh's typed phrase and
# cool-off delay are friction for a human, not a test fixture. Times come
# from the guest's pinned clock.
guest_now="$(probe 'date +%s')"
guest "echo $guest_now\|$((guest_now + 7200))\|$guest_now\|vmbox-e2e-unlock-phase | sudo tee -a /etc/shutdown-schedule-overrides.conf" >/dev/null ||
	fail "could not register an override"
start=$SECONDS
guest "sudo /usr/local/bin/night-lockdown-unlock.sh" >"$TMP_DIR/unlock.log" || fail "unlock failed"
unlock_s=$((SECONDS - start))
(( unlock_s < 90 )) || fail "unlock took ${unlock_s}s: something in it hangs (openrgb?)"
grep -q 'night lockdown lifted' "$TMP_DIR/unlock.log" || fail "unlock did not reach its final line"
ok "unlock ran to completion in ${unlock_s}s with the hung openrgb"
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
	[[ "$(probe 'systemctl is-active lightdm.service')" == active ]] && break
	sleep 3
done
[[ "$(probe 'systemctl is-active lightdm.service')" == active ]] || fail "lightdm did not come back"
[[ "$(probe 'systemctl is-enabled lightdm.service')" != masked ]] || fail "lightdm is still masked"
[[ "$(probe 'systemctl is-enabled getty@.service')" != masked ]] || fail "getty@ is still masked"
[[ "$(probe 'cat /var/lib/night-lockdown/state')" == UNLOCKED ]] || fail "state is not UNLOCKED"
sleep 10
vm screenshot "$VM" "$TMP_DIR/unlocked.png" >/dev/null
unlocked_mean="$(python3 "$SCRIPT_DIR/lib/png_brightness.py" "$TMP_DIR/unlocked.png")"
(( unlocked_mean > locked_mean )) ||
	fail "screen still black after unlock (mean brightness $unlocked_mean)"
ok "desktop is back (mean brightness $unlocked_mean)"

printf '\nvmbox_night_lockdown: %d passed, 0 failed\n' "$passed"
