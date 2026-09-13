#!/bin/bash
# Regression tests for the night-lockdown enforcement gate.
#
# The bug this guards: the enter script used to skip its work whenever the
# state file said LOCKED. That token survives a power-cycle but the lockdown
# does not (lightdm is an enabled unit), so on 2026-09-12 a reboot one minute
# after the 00:00 lock left a fully usable desktop with every later curfew tick
# logging "already LOCKED - nothing to do" until 05:00. The gate must check the
# observable effects, and the mask/unmask pair must always ship together.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENTER_SRC="$REPO_DIR/lib/payloads/night-lockdown-enter.sh.in"
UNLOCK_SRC="$REPO_DIR/lib/payloads/night-lockdown-unlock.sh.in"

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

# Build a runnable copy of the enter payload with its hardcoded /var and /etc
# paths redirected into the sandbox, so the gate can be exercised as a
# non-root user without touching real state.
STATE_DIR="$TMP_DIR/state"
mkdir -p "$STATE_DIR" "$TMP_DIR/bin"
ENTER="$TMP_DIR/enter.sh"
sed -e "s#^readonly STATE_DIR=.*#readonly STATE_DIR=\"$STATE_DIR\"#" \
	-e "s#^readonly CONF_FILE=.*#readonly CONF_FILE=\"$TMP_DIR/night-lockdown.conf\"#" \
	-e "s#^readonly COSMETICS_SCRIPT=.*#readonly COSMETICS_SCRIPT=\"$TMP_DIR/cosmetics.sh\"#" \
	"$ENTER_SRC" >"$ENTER"
chmod +x "$ENTER"
: >"$TMP_DIR/night-lockdown.conf"

# Stub systemctl: answers come from files the test writes, so each scenario
# describes the machine's real state rather than the script's intent.
cat >"$TMP_DIR/bin/systemctl" <<'STUB'
#!/bin/bash
case "$1 $2" in
"is-enabled getty@.service") cat "$STUB_DIR/getty_enabled" ;;
"is-enabled lightdm.service") cat "$STUB_DIR/dm_enabled" ;;
"is-active --quiet") [[ "$(cat "$STUB_DIR/dm_active")" == "active" ]] ;;
*) printf '%s\n' "$*" >>"$STUB_DIR/calls" ;;
esac
STUB
chmod +x "$TMP_DIR/bin/systemctl"
printf '#!/bin/bash\nexit 0\n' >"$TMP_DIR/bin/logger"
chmod +x "$TMP_DIR/bin/logger"
export STUB_DIR="$TMP_DIR"
export PATH="$TMP_DIR/bin:$PATH"

run_enter() {
	# DRY_RUN keeps every real action log-only; the gate itself runs for real.
	DRY_RUN=1 bash "$ENTER" 2>&1 || true
}

printf '\nenter gate: a LOCKED token with the lockdown actually in force is a no-op\n'
echo LOCKED >"$STATE_DIR/state"
echo masked >"$TMP_DIR/getty_enabled"
echo masked >"$TMP_DIR/dm_enabled"
echo inactive >"$TMP_DIR/dm_active"
out="$(run_enter)"
grep -q 'already LOCKED and enforced' <<<"$out" ||
	fail "an actually-enforced lockdown should short-circuit"
ok "an enforced lockdown short-circuits"
grep -q 'entering night lockdown' <<<"$out" &&
	fail "an enforced lockdown must not re-run the teardown"
ok "it does not re-run the teardown"

printf '\nenter gate: a LOCKED token with the GUI back up re-applies (the reboot bypass)\n'
echo LOCKED >"$STATE_DIR/state"
echo masked >"$TMP_DIR/getty_enabled"
echo enabled >"$TMP_DIR/dm_enabled"
echo active >"$TMP_DIR/dm_active"
out="$(run_enter)"
grep -q 'already LOCKED and enforced' <<<"$out" &&
	fail "a stale LOCKED token must not be trusted when the GUI is up"
ok "a stale LOCKED token is not trusted"
grep -q 'enforcement is NOT in effect' <<<"$out" ||
	fail "the mismatch should be logged"
ok "the mismatch is logged"
grep -q 'entering night lockdown' <<<"$out" ||
	fail "the lockdown should be re-applied"
ok "the lockdown is re-applied"

printf '\nenter gate: a LOCKED token with the login surface unmasked re-applies\n'
echo LOCKED >"$STATE_DIR/state"
echo enabled >"$TMP_DIR/getty_enabled"
echo masked >"$TMP_DIR/dm_enabled"
echo inactive >"$TMP_DIR/dm_active"
out="$(run_enter)"
grep -q 'entering night lockdown' <<<"$out" ||
	fail "an unmasked getty means enforcement is gone; re-apply"
ok "an unmasked getty re-applies the lockdown"

printf '\nenter gate: an UNLOCKED token always proceeds\n'
echo UNLOCKED >"$STATE_DIR/state"
echo masked >"$TMP_DIR/getty_enabled"
echo masked >"$TMP_DIR/dm_enabled"
echo inactive >"$TMP_DIR/dm_active"
out="$(run_enter)"
grep -q 'entering night lockdown' <<<"$out" ||
	fail "UNLOCKED must always enter"
ok "UNLOCKED always enters"

printf '\nmask/unmask pairing: enter masks the display manager, unlock unmasks it\n'
grep -qE '^run systemctl mask .*DISPLAY_MANAGER_UNIT' "$ENTER_SRC" ||
	fail "enter must mask the display manager, not merely stop it"
ok "enter masks the display manager"
grep -qE '^run systemctl unmask .*DISPLAY_MANAGER_UNIT' "$UNLOCK_SRC" ||
	fail "unlock must unmask the display manager or the GUI never returns"
ok "unlock unmasks the display manager"
grep -qE '^run systemctl mask .*DISPLAY_MANAGER_UNIT' "$UNLOCK_SRC" &&
	fail "unlock must never mask the display manager"
ok "unlock never masks it"

printf '\nno unbounded openrgb call anywhere in the lock/unlock pair\n'
for src in "$ENTER_SRC" "$UNLOCK_SRC" "$REPO_DIR/lib/payloads/night-lockdown-cosmetics.sh.in"; do
	grep -nE '^\s*run (env [^ ]+ )?openrgb' "$src" &&
		fail "$(basename "$src"): openrgb must run under timeout (1.0-2 never returns)"
done
ok "every openrgb call is bounded"
unlock_state_line="$(grep -n 'echo UNLOCKED >' "$UNLOCK_SRC" | cut -d: -f1)"
unlock_rgb_line="$(grep -n 'openrgb --mode' "$UNLOCK_SRC" | cut -d: -f1)"
[[ -n "$unlock_state_line" && -n "$unlock_rgb_line" && "$unlock_state_line" -lt "$unlock_rgb_line" ]] ||
	fail "unlock must record UNLOCKED before its cosmetic tail (state $unlock_state_line vs openrgb $unlock_rgb_line)"
ok "unlock records UNLOCKED before touching openrgb"

printf '\nprintk capture is guarded so re-entry cannot record the silenced value\n'
grep -qE '! -f .*STATE_DIR/printk[.]prev' "$ENTER_SRC" ||
	fail "printk.prev capture must be guarded like cpu_epp.prev"
ok "printk.prev capture is guarded"
grep -qE 'rm -f .*STATE_DIR/printk[.]prev' "$UNLOCK_SRC" ||
	fail "unlock must delete printk.prev so the next night captures fresh"
ok "unlock deletes printk.prev"

printf '\ntest_night_lockdown_enforcement: %d passed, 0 failed\n' "$passed"
