#!/bin/bash
# Regression test: the morning unlock must actually bring the GUI back.
#
# On 2026-11-20 the nightly auto-update installed nvidia-utils 620.73 and
# kernel 7.3.5 while the PC sat in lockdown. At 05:00 the unlock started
# lightdm, Xorg died on "NVRM: API mismatch" (module still 620.70), lightdm hit
# its start limit, and the script still wrote UNLOCKED. Every later trigger
# (05:15 .. 07:00) printed "already UNLOCKED" and the PC stayed on the text
# console all morning. This test runs the real unlock + recover scripts against
# a PATH of stubs whose state lives in flag files, and asserts:
#   - UNLOCKED with the display manager down is retried, not skipped;
#   - a failed unit is reset-failed before the start;
#   - a driver mismatch is reloaded when the running kernel still has modules;
#   - it reboots (once a day) when the driver cannot be loaded at all.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
UNLOCK_SRC="$REPO_DIR/lib/payloads/night-lockdown-unlock.sh"
RECOVER_SRC="$REPO_DIR/lib/payloads/night-lockdown-gui-recover.sh"

passed=0
fail() {
	printf 'FAIL: %s\n' "$1" >&2
	printf -- '--- calls ---\n%s\n--- out ---\n%s\n' "$(cat "$CALLS")" "$(cat "$OUT")" >&2
	exit 1
}
ok() {
	printf '  OK: %s\n' "$1"
	passed=$((passed + 1))
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
STATE_DIR="$TMP_DIR/state"
FLAGS="$TMP_DIR/flags"
CALLS="$TMP_DIR/calls"
OUT="$TMP_DIR/out"
MODULES="$TMP_DIR/modules"
mkdir -p "$STATE_DIR" "$FLAGS" "$TMP_DIR/bin"

UNLOCK="$TMP_DIR/unlock.sh"
RECOVER="$TMP_DIR/recover.sh"
redirect=(-e "s#^readonly STATE_DIR=.*#readonly STATE_DIR=\"$STATE_DIR\"#"
	-e "s#^readonly CONF_FILE=.*#readonly CONF_FILE=\"$TMP_DIR/night-lockdown.conf\"#"
	-e "s#^readonly GUI_RECOVER_SCRIPT=.*#readonly GUI_RECOVER_SCRIPT=\"$RECOVER\"#")
sed "${redirect[@]}" "$UNLOCK_SRC" >"$UNLOCK"
[[ -f "$RECOVER_SRC" ]] && sed "${redirect[@]}" "$RECOVER_SRC" >"$RECOVER"
chmod +x "$UNLOCK" "$RECOVER" 2>/dev/null || true

cat >"$TMP_DIR/night-lockdown.conf" <<CONF
RGB_ENABLE="0"
POWER_SAVE_ENABLE="0"
ALSA_CARDS=""
CONSOLE_TTY="$TMP_DIR/tty"
DM_SETTLE_SECONDS="0"
KERNEL_MODULES_DIR="$MODULES"
CONF
: >"$TMP_DIR/tty"

# One stub for every tool; behaviour keyed on the flag files.
cat >"$TMP_DIR/bin/stub" <<'STUB'
#!/bin/bash
tool="$(basename "$0")"
printf '%s %s\n' "$tool" "$*" >>"$CALLS_FILE"
case "$tool $1" in
"systemctl is-active") [[ -e "$FLAGS_DIR/dm_active" ]] ;;
"systemctl start") [[ -e "$FLAGS_DIR/dm_startable" ]] && touch "$FLAGS_DIR/dm_active"; exit 0 ;;
nvidia-smi*) [[ -e "$FLAGS_DIR/nvidia_ok" ]] ;;
"modprobe -r") exit 0 ;;
modprobe*) [[ -e "$FLAGS_DIR/reload_fixes" ]] && touch "$FLAGS_DIR/nvidia_ok" "$FLAGS_DIR/dm_startable"; exit 0 ;;
*) exit 0 ;;
esac
STUB
chmod +x "$TMP_DIR/bin/stub"
for tool in systemctl nvidia-smi modprobe sysctl setterm logger amixer sudo openrgb autorandr; do
	ln -s stub "$TMP_DIR/bin/$tool"
done
export CALLS_FILE="$CALLS" FLAGS_DIR="$FLAGS" PATH="$TMP_DIR/bin:$PATH"

# scenario <state> <flag...>: fresh flags + calls, then run unlock once.
scenario() {
	local state="$1"
	shift
	rm -f "$FLAGS"/*
	: >"$CALLS"
	echo "$state" >"$STATE_DIR/state"
	local f
	for f in "$@"; do touch "$FLAGS/$f"; done
	bash "$UNLOCK" >"$OUT" 2>&1 || fail "unlock exited non-zero"
}
called() { grep -q "^$1" "$CALLS"; }
line_of() { grep -n "^$1" "$CALLS" | head -1 | cut -d: -f1; }

printf '\nUNLOCKED but the GUI is down: retried, not skipped\n'
mkdir -p "$MODULES"
scenario UNLOCKED nvidia_ok dm_startable
called 'systemctl start lightdm.service' ||
	fail "an UNLOCKED morning with lightdm down must start lightdm again"
ok "lightdm started although state was UNLOCKED"
rf="$(line_of 'systemctl reset-failed lightdm.service')"
st="$(line_of 'systemctl start lightdm.service')"
[[ -n "$rf" && "$rf" -lt "$st" ]] ||
	fail "reset-failed must precede start, or a start-limit-hit unit refuses it"
ok "reset-failed ran before start"
[[ -e "$FLAGS/dm_active" ]] || fail "lightdm must end active"
ok "lightdm ends active"

printf '\nUNLOCKED and the GUI is up: a no-op\n'
scenario UNLOCKED nvidia_ok dm_active
called 'systemctl start' && fail "must not restart a running GUI"
grep -q 'already UNLOCKED' "$OUT" || fail "expected the no-op log line"
ok "running GUI left alone"

printf '\ndriver mismatch, modules present: reload, no reboot\n'
scenario LOCKED reload_fixes
called 'modprobe -r' || fail "a driver mismatch must try a module reload"
ok "nvidia modules reloaded"
called 'systemctl reboot' && fail "a reload that fixed it must not reboot"
ok "no reboot"
[[ -e "$FLAGS/dm_active" ]] || fail "lightdm must end active after the reload"
ok "lightdm active after the reload"
[[ "$(cat "$STATE_DIR/state")" == "UNLOCKED" ]] || fail "state must be UNLOCKED"
ok "state UNLOCKED"

printf '\ndriver mismatch, running kernel modules gone: reboot once\n'
rm -rf "$MODULES"
scenario LOCKED
called 'systemctl reboot' ||
	fail "the driver cannot load on this kernel; the unlock must reboot"
ok "rebooted to load the new kernel + driver"
called 'systemctl start lightdm.service' &&
	fail "must not start lightdm against a driver that cannot load"
ok "no doomed lightdm start"
: >"$CALLS"
bash "$UNLOCK" >"$OUT" 2>&1 || fail "second run exited non-zero"
called 'systemctl reboot' && fail "a second trigger the same day must not reboot again"
grep -q 'WARN' "$OUT" || fail "the skipped reboot must be logged as a WARN"
ok "second trigger the same day does not reboot again"

printf '\nhealthy driver, normal lockdown: plain start, no reboot\n'
mkdir -p "$MODULES"
scenario LOCKED nvidia_ok dm_startable
called 'modprobe' && fail "a healthy driver must not be reloaded"
called 'systemctl reboot' && fail "a healthy morning must not reboot"
[[ -e "$FLAGS/dm_active" ]] || fail "lightdm must end active"
ok "plain start, nothing else"

printf '\ntest_night_lockdown_gui_recover: %d passed, 0 failed\n' "$passed"
