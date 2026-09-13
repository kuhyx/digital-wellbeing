#!/bin/bash
# Regression test: a cosmetic tool that never returns cannot delay or defeat
# the night lockdown.
#
# On 2026-09-12 23:00 the enter script called openrgb (1.0-2, which hangs in a
# hidraw read on this hardware) BEFORE masking anything. It logged "entering
# night lockdown" and then sat there all night; the desktop stayed usable and
# the oneshot never exited, so every later per-minute tick was a no-op. The
# fix is structural: enforcement first, cosmetics last, in a child bounded by
# `timeout`. This test runs the real scripts (no DRY_RUN) against a PATH of
# stubs, with an openrgb that sleeps forever, and asserts from the recorded
# calls that enforcement landed first and the whole run finished quickly.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENTER_SRC="$REPO_DIR/lib/payloads/night-lockdown-enter.sh.in"
COSMETICS_SRC="$REPO_DIR/lib/payloads/night-lockdown-cosmetics.sh.in"

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
cleanup() {
	# The fake openrgb sleeps forever; make sure none outlives the test.
	pkill -f "sleep $HANG_SLEEP" 2>/dev/null || true
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

STATE_DIR="$TMP_DIR/state"
# Output goes to a FILE, never a $(...) pipe: an orphaned tool holding the
# pipe would turn a regression into a hang instead of a failure.
OUT="$TMP_DIR/out"
# A unique sleep so cleanup can find (and the assertion can spot) the fake
# openrgb without touching anybody else's sleep.
HANG_SLEEP="31536000$$"
CALLS="$TMP_DIR/calls"
mkdir -p "$STATE_DIR" "$TMP_DIR/bin"
: >"$CALLS"

# Runnable copies with /var, /etc and the cosmetics path redirected into the
# sandbox, so this runs as a normal user without touching real state.
ENTER="$TMP_DIR/enter.sh"
COSMETICS="$TMP_DIR/cosmetics.sh"
sed -e "s#^readonly STATE_DIR=.*#readonly STATE_DIR=\"$STATE_DIR\"#" \
	-e "s#^readonly CONF_FILE=.*#readonly CONF_FILE=\"$TMP_DIR/night-lockdown.conf\"#" \
	-e "s#^readonly COSMETICS_SCRIPT=.*#readonly COSMETICS_SCRIPT=\"$COSMETICS\"#" \
	"$ENTER_SRC" >"$ENTER"
sed -e "s#^readonly STATE_DIR=.*#readonly STATE_DIR=\"$STATE_DIR\"#" \
	-e "s#^readonly CONF_FILE=.*#readonly CONF_FILE=\"$TMP_DIR/night-lockdown.conf\"#" \
	"$COSMETICS_SRC" >"$COSMETICS"
chmod +x "$ENTER" "$COSMETICS"

cat >"$TMP_DIR/night-lockdown.conf" <<CONF
RGB_ENABLE="1"
POWER_SAVE_ENABLE="0"
ALSA_CARDS="0"
CONSOLE_TTY="$TMP_DIR/tty"
CONF
: >"$TMP_DIR/tty"

# Every external tool records its argv and returns success — except openrgb,
# which never returns at all. systemctl answers the enforcement gate as
# "nothing is masked, the GUI is up" so the script must do the full teardown.
for tool in systemctl systemd-run sysctl setterm logger nvidia-smi amixer sudo; do
	cat >"$TMP_DIR/bin/$tool" <<'STUB'
#!/bin/bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$CALLS_FILE"
case "$(basename "$0") $1" in
"systemctl is-enabled") echo enabled ;;
"systemctl is-active") exit 0 ;;
esac
exit 0
STUB
	chmod +x "$TMP_DIR/bin/$tool"
done
sed "s/__HANG_SLEEP__/$HANG_SLEEP/" >"$TMP_DIR/bin/openrgb" <<'STUB'
#!/bin/bash
printf 'openrgb %s\n' "$*" >>"$CALLS_FILE"
exec sleep __HANG_SLEEP__
STUB
chmod +x "$TMP_DIR/bin/openrgb"
export CALLS_FILE="$CALLS"
export PATH="$TMP_DIR/bin:$PATH"

printf '\na hung openrgb never delays enforcement\n'
echo UNLOCKED >"$STATE_DIR/state"
start=$SECONDS
# Tight budgets so the test is fast; production defaults are 120s / 30s.
COSMETICS_TIMEOUT=4 TOOL_TIMEOUT=2 bash "$ENTER" >"$OUT" 2>&1 || true
out="$(cat "$OUT")"
elapsed=$((SECONDS - start))
[[ $elapsed -le 15 ]] ||
	fail "enter took ${elapsed}s with a hung openrgb; it must be bounded"
ok "enter returned in ${elapsed}s despite a never-returning openrgb"

grep -q 'night lockdown active' <<<"$out" ||
	fail "enter must reach its final log line: $out"
ok "enter ran to completion"
[[ "$(cat "$STATE_DIR/state")" == "LOCKED" ]] ||
	fail "state must be LOCKED"
ok "state is LOCKED"

# Order: every enforcement call must be recorded before the first openrgb.
first_rgb="$(grep -n '^openrgb ' "$CALLS" | head -1 | cut -d: -f1)"
[[ -n "$first_rgb" ]] || fail "openrgb was never invoked — the stub is not on PATH"
for needle in 'systemctl mask getty@.service' 'systemctl mask lightdm.service' \
	'systemctl stop lightdm.service' 'systemd-run '; do
	line="$(grep -n "^$needle" "$CALLS" | head -1 | cut -d: -f1)"
	[[ -n "$line" ]] || fail "enforcement call missing: $needle"
	[[ "$line" -lt "$first_rgb" ]] ||
		fail "'$needle' (call #$line) ran after openrgb (call #$first_rgb)"
done
ok "getty mask, DM mask, DM stop and the wake floor all precede openrgb"
stop_floor="$(grep -n '^systemctl stop night-lockdown-wake-floor.timer' "$CALLS" | head -1 | cut -d: -f1)"
sched_floor="$(grep -n '^systemd-run ' "$CALLS" | head -1 | cut -d: -f1)"
[[ -n "$stop_floor" && "$stop_floor" -lt "$sched_floor" ]] ||
	fail "a previous wake-floor timer must be stopped before the new one is scheduled (re-entry left the floor unscheduled)"
ok "a stale wake-floor timer is cleared before rescheduling"

grep -q 'WARN: command failed (continuing): timeout .*openrgb' <<<"$out" ||
	fail "the per-tool timeout on openrgb must be reported, not hidden: $out"
ok "the killed openrgb is logged as a WARN"
pgrep -f "sleep $HANG_SLEEP" >/dev/null &&
	fail "the hung openrgb is still running: timeout must KILL, not just TERM"
ok "the hung openrgb was actually killed"

printf '\nthe outer budget holds even if the per-tool one is misconfigured\n'
echo UNLOCKED >"$STATE_DIR/state"
: >"$CALLS"
start=$SECONDS
COSMETICS_TIMEOUT=2 TOOL_TIMEOUT=600 bash "$ENTER" >"$OUT" 2>&1 || true
out="$(cat "$OUT")"
elapsed=$((SECONDS - start))
[[ $elapsed -le 20 ]] ||
	fail "enter took ${elapsed}s: the outer cosmetics timeout did not fire"
ok "enter returned in ${elapsed}s with only the outer timeout to rely on"
grep -q 'WARN: cosmetics failed or timed out' <<<"$out" ||
	fail "the cosmetics timeout must be reported, not hidden: $out"
ok "the outer timeout is logged as a WARN"
grep -q 'night lockdown active' <<<"$out" ||
	fail "enter must still reach its final log line"
ok "enter still ran to completion"

printf '\na hung openrgb does not starve the other cosmetic steps\n'
# The cosmetics script on its own: openrgb is bounded per tool, so amixer
# (listed after it) must still run within the parent's budget.
: >"$CALLS"
TOOL_TIMEOUT=1 timeout 10 bash "$COSMETICS" >"$OUT" 2>&1 || true
out="$(cat "$OUT")"
grep -q '^amixer ' "$CALLS" ||
	fail "amixer never ran: a hung openrgb consumed the whole cosmetics budget"
ok "amixer still ran after the bounded openrgb"
grep -q 'cosmetics done' <<<"$out" ||
	fail "cosmetics must reach its final log line: $out"
ok "cosmetics ran to completion"

printf '\ntest_night_lockdown_hang: %d passed, 0 failed\n' "$passed"
