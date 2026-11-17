#!/bin/bash
# Tests for the evening-chain deferral in the per-minute shutdown check.
#
# Contract: when the check would enter night lockdown in the EVENING
# (shutdown_start <= now < 23:00, not LOCKED, no override), it first asks
# `gatelock.evening_chain pending`. Exit 0 (unpaid rungs) starts the user unit
# evening-gates.service and skips the entry for this tick. Every other outcome
# (exit 1, exit 2, timeout, start failure, unit ended after it was started
# tonight) enters lockdown exactly as before: FAIL CLOSED. Mornings and
# >= 23:00 never consult the chain.
#
# The wall clock is replaced by sed-patching the minutes-of-day line, and the
# pending CLI, systemctl, logger and enter/unlock are stubs.

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

CALLS="$TMP_DIR/calls"
LOG="$TMP_DIR/log"
STAMPS="$TMP_DIR/stamps"
printf -v TODAY '%(%Y-%m-%d)T' -1

# shellcheck disable=SC2016 # ${FAKE_MIN} must reach the payload unexpanded
CLOCK_SEAM='current_time_minutes=${FAKE_MIN:?}'
CHECK="$TMP_DIR/check.sh"
sed -e "s#^CONFIG_FILE=.*#CONFIG_FILE=\"$TMP_DIR/schedule.conf\"#" \
	-e "s#^OVERRIDES_FILE=.*#OVERRIDES_FILE=\"$TMP_DIR/overrides.conf\"#" \
	-e "s#^LOCKDOWN_STATE_FILE=.*#LOCKDOWN_STATE_FILE=\"$TMP_DIR/state\"#" \
	-e "s#^UNLOCK_SCRIPT=.*#UNLOCK_SCRIPT=\"$TMP_DIR/unlock.sh\"#" \
	-e "s#^CHAIN_STATE_DIR=.*#CHAIN_STATE_DIR=\"$STAMPS\"#" \
	-e "s#^PENDING_CMD=.*#PENDING_CMD=(\"$TMP_DIR/pending.sh\")#" \
	-e "s#^PENDING_TIMEOUT=.*#PENDING_TIMEOUT=1#" \
	-e "s#^current_time_minutes=.*#$CLOCK_SEAM#" \
	-e "s#/usr/local/bin/night-lockdown-enter.sh#$TMP_DIR/enter.sh#g" \
	"$CHECK_SRC" >"$CHECK"
# The seams must exist in the payload, or the stubs below would be bypassed.
for seam in CHAIN_STATE_DIR PENDING_CMD PENDING_TIMEOUT; do
	grep -q "^$seam=" "$CHECK" || fail "payload has no $seam seam"
done
grep -q 'FAKE_MIN' "$CHECK" || fail "clock seam did not apply"

printf '#!/bin/bash\necho enter >>"%s"\n' "$CALLS" >"$TMP_DIR/enter.sh"
printf '#!/bin/bash\necho unlock >>"%s"\n' "$CALLS" >"$TMP_DIR/unlock.sh"
# Pending CLI stub: behaviour comes from files in $TMP_DIR, so each case only
# writes the files it needs. HOME is recorded to prove the kuhy-compatible env.
cat >"$TMP_DIR/pending.sh" <<STUB
#!/bin/bash
echo "pending home=\$HOME" >>"$CALLS"
[[ -f "$TMP_DIR/pending_sleep" ]] && sleep 30
[[ -f "$TMP_DIR/pending_out" ]] && cat "$TMP_DIR/pending_out"
exit "\$(cat "$TMP_DIR/pending_rc")"
STUB
mkdir -p "$TMP_DIR/bin"
# systemctl stub: is-active succeeds while $TMP_DIR/unit_active exists; start
# creates it unless start_fails / start_dies is present.
cat >"$TMP_DIR/bin/systemctl" <<STUB
#!/bin/bash
echo "systemctl \$*" >>"$CALLS"
case "\$*" in
*is-active*) [[ -f "$TMP_DIR/unit_active" ]] ;;
*start*)
	[[ -f "$TMP_DIR/start_fails" ]] && exit 1
	[[ -f "$TMP_DIR/start_dies" ]] || : >"$TMP_DIR/unit_active"
	;;
*) exit 1 ;;
esac
STUB
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$LOG" >"$TMP_DIR/bin/logger"
chmod +x "$TMP_DIR"/*.sh "$TMP_DIR"/bin/*
export PATH="$TMP_DIR/bin:$PATH"

# Shutdown from 20:00 (1200) every day, morning end 05:00.
printf 'MON_WED_HOUR=20\nTHU_SUN_HOUR=20\nMORNING_END_HOUR=5\n' >"$TMP_DIR/schedule.conf"

# run_case <minute-of-day> <pending_rc> [state]; extra setup via files first.
run_case() {
	: >"$CALLS"
	: >"$LOG"
	rm -f "$TMP_DIR/overrides.conf"
	printf '%s\n' "${3:-UNLOCKED}" >"$TMP_DIR/state"
	printf '%s\n' "$2" >"$TMP_DIR/pending_rc"
	FAKE_MIN="$1" bash "$CHECK" >/dev/null 2>&1 || fail "check exited non-zero (min=$1 rc=$2)"
}
reset_case() {
	rm -rf "$STAMPS" "$TMP_DIR"/{unit_active,start_fails,start_dies,pending_sleep,pending_out}
	mkdir -p "$STAMPS"
}
calls() { tr '\n' '|' <"$CALLS"; }
entered() { grep -qx enter "$CALLS"; }
called() { grep -q "$1" "$CALLS"; }
logged() { grep -q -- "$1" "$LOG"; }

EVENING=1260 # 21:00
echo "test_shutdown_check_evening_chain.sh"

reset_case
printf 'reading tutor\n' >"$TMP_DIR/pending_out"
run_case $EVENING 0
entered && fail "pending + unit started must defer, got: $(calls)"
called 'pending home=/home/kuhy' || fail "pending CLI not run with HOME=/home/kuhy: $(calls)"
called 'systemctl --user -M kuhy@ start evening-gates.service' || fail "unit not started: $(calls)"
logged 'deferred: evening chain pending: reading tutor' || fail "no deferred log: $(cat "$LOG")"
[[ -e "$STAMPS/chain_started_$TODAY" ]] || fail "no chain_started stamp"
ok "pending rungs + unit started: deferred, no lockdown, started stamp written"

# Unit already running: no second start, still deferred.
run_case $EVENING 0
entered && fail "active unit must keep deferring"
called ' start ' && fail "an active unit must not be started again: $(calls)"
ok "already-active unit keeps deferring without a restart"

# Kuhy ended the chain: unit was started earlier tonight, now inactive.
reset_case
: >"$STAMPS/chain_started_$TODAY"
run_case $EVENING 0
entered || fail "started earlier + now inactive must enter, got: $(calls)"
[[ -e "$STAMPS/chain_ended_$TODAY" ]] || fail "no chain_ended stamp"
called ' start ' && fail "ended chain must not be restarted: $(calls)"
ok "unit started earlier and now inactive: lockdown + chain_ended stamp"

# Next minute: ended stamp -> straight to lockdown, CLI untouched.
run_case $EVENING 0
entered || fail "chain_ended must enter"
called pending && fail "chain_ended must skip the CLI: $(calls)"
ok "chain_ended stamp: lockdown, CLI not called"

reset_case
run_case $EVENING 1
entered || fail "pending exit 1 must enter, got: $(calls)"
called ' start ' && fail "exit 1 must not start the unit"
ok "pending exit 1 (nothing pending/free/sick): lockdown"

reset_case
run_case $EVENING 2
entered || fail "pending exit 2 must enter (fail closed)"
logged 'ERROR: evening chain' || fail "exit 2 not logged as error: $(cat "$LOG")"
called ' start ' && fail "exit 2 must not start the unit"
ok "pending exit 2 (could not check): lockdown + error log"

reset_case
: >"$TMP_DIR/pending_sleep"
run_case $EVENING 0
entered || fail "pending timeout must enter (fail closed)"
logged 'ERROR: evening chain' || fail "timeout not logged as error: $(cat "$LOG")"
ok "pending timeout: lockdown + error log"

reset_case
: >"$TMP_DIR/start_fails"
run_case $EVENING 0
entered || fail "start failure must enter (fail closed)"
logged 'ERROR: evening chain' || fail "start failure not logged as error"
ok "unit start failure: lockdown + error log"

reset_case
: >"$TMP_DIR/start_dies"
run_case $EVENING 0
entered || fail "unit that dies at once must enter (fail closed)"
[[ -e "$STAMPS/chain_ended_$TODAY" ]] || fail "dead-on-start unit must write chain_ended"
ok "unit inactive right after start: lockdown + chain_ended stamp"

# >= 23:00: unchanged, CLI never called.
reset_case
run_case 1400 0
entered || fail "23:20 must enter"
called pending && fail "CLI must not run at >= 23:00: $(calls)"
run_case 1380 0
entered || fail "exactly 23:00 must enter"
called pending && fail "CLI must not run at 23:00"
ok ">= 23:00: lockdown as before, CLI not called"

# Morning window (02:00, inside 00:00-05:00): CLI never called.
reset_case
run_case 120 0
entered || fail "morning window must enter"
called pending && fail "CLI must not run in the morning window: $(calls)"
ok "morning window: lockdown as before, CLI not called"

# Already LOCKED in the evening: straight to the (idempotent) enter.
reset_case
run_case $EVENING 0 LOCKED
entered || fail "LOCKED must re-enter"
called pending && fail "CLI must not run when already LOCKED: $(calls)"
ok "already LOCKED: re-enter as before, CLI not called"

# Active override exits before anything: CLI not called.
reset_case
printf -v now '%(%s)T' -1
: >"$CALLS"
printf '%s\n' UNLOCKED >"$TMP_DIR/state"
printf '%s|%s|%s|test\n' "$((now - 60))" "$((now + 3600))" "$now" >"$TMP_DIR/overrides.conf"
FAKE_MIN=$EVENING bash "$CHECK" >/dev/null 2>&1
called pending && fail "CLI must not run under an override"
entered && fail "override must not enter"
ok "active override: no CLI, no lockdown"

# Before the window nothing happens at all.
reset_case
run_case 600 0
[[ -z "$(calls)" ]] || fail "outside the window nothing may run, got: $(calls)"
ok "outside the window: no CLI, no lockdown (tick stays cheap)"

# DRY_RUN must not start real GUI gates.
reset_case
: >"$CALLS"
DRY_RUN=1 FAKE_MIN=$EVENING bash "$CHECK" >/dev/null 2>&1
called ' start ' && fail "DRY_RUN must not start the unit: $(calls)"
ok "DRY_RUN never starts the unit"

# Old stamps are pruned, today's survive.
reset_case
: >"$STAMPS/chain_started_2000-01-01"
: >"$STAMPS/chain_ended_2000-01-01"
: >"$STAMPS/unrelated"
run_case $EVENING 1
[[ ! -e "$STAMPS/chain_started_2000-01-01" && ! -e "$STAMPS/chain_ended_2000-01-01" ]] || fail "old chain stamps not pruned"
[[ -e "$STAMPS/unrelated" ]] || fail "prune touched a non-chain file"
ok "chain stamps from other days are pruned"

printf 'All %d checks passed.\n' "$passed"
