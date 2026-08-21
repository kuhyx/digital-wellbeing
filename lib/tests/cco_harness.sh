#!/usr/bin/env bash
# lib/tests/cco_harness.sh — shared fixture for the block_compulsive_opening.sh split.
#
# Sourced, not executed. Scope: the hour-key/state logic that decides whether an
# app launch is allowed. Everything that moves system binaries (install_wrapper,
# uninstall_wrapper, install_all) or kills processes (kill_app, launch_with_timer)
# is NOT executed here — this machine's beeper/signal/discord wrappers and a live
# pacman hook depend on those paths, and a test that ran them would rewrite them.
#
# STATE_DIR and LOG_FILE were already variables in the pre-split script, so the
# tests point them at a tmpdir and nothing touches ~/.local/state.
set -euo pipefail

PASS=0
FAIL=0

_t_pass() {
	PASS=$((PASS + 1))
	printf '  OK: %s\n' "$1"
}

_t_fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL: %s\n' "$1"
}

_t_eq() {
	local want="$1"
	local got="$2"
	local what="$3"
	if [[ $got == "$want" ]]; then
		_t_pass "$what"
	else
		_t_fail "$what (want '${want}', got '${got}')"
	fi
}

_t_has() {
	local haystack="$1"
	local needle="$2"
	local what="$3"
	if [[ $haystack == *"$needle"* ]]; then
		_t_pass "$what"
	else
		_t_fail "$what (want a substring '${needle}')"
	fi
}

# These helpers return 0/1 to mean allowed/blocked, and which way they fail is
# the whole point — assert on the status explicitly rather than letting `set -e`
# end the run. Called via `if` so a non-zero return does not abort the suite.
_t_true() {
	local what="$2"
	if ("$1"); then
		_t_pass "$what"
	else
		_t_fail "$what (expected success, got non-zero)"
	fi
}

_t_false() {
	local what="$2"
	if ("$1"); then
		_t_fail "$what (expected non-zero, got success)"
	else
		_t_pass "$what"
	fi
}

CCO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CCO_LIB_DIR

# Stand in for the globals the entry script defines before sourcing the libs.
_t_cco_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	export TEST_TMPDIR

	STATE_DIR="$TEST_TMPDIR/state"
	LOG_FILE="$STATE_DIR/compulsive-block.log"
	mkdir -p "$STATE_DIR"

	AUTO_CLOSE_TIMEOUT_MINUTES=10
	AUTO_CLOSE_WARNING_MINUTES=2

	declare -gA APP_TIMEOUT_MINUTES=(["beeper"]=20 ["signal-desktop"]=20)
	declare -gA APPS=(
		["beeper"]="$TEST_TMPDIR/bin/beeper"
		["signal-desktop"]="$TEST_TMPDIR/bin/signal-desktop"
		["discord"]="$TEST_TMPDIR/bin/discord"
	)
	declare -gA REAL_BINARIES=(
		["beeper"]="$TEST_TMPDIR/real/beepertexts"
		["signal-desktop"]="$TEST_TMPDIR/real/signal-desktop"
		["discord"]="$TEST_TMPDIR/bin/discord.orig"
	)
	declare -gA PROCESS_MATCH=(["discord"]="$TEST_TMPDIR/home/.config/discord/")

	mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/real"

	# notify() is defined in the entry script, which the tests never source.
	notify() { printf 'NOTIFY: %s | %s\n' "$1" "$2" >>"$TEST_TMPDIR/notifications"; }
	: >"$TEST_TMPDIR/notifications"

	_t_cco_assert_fixture_complete
}

# Every global above is read by the sourced lib, never by this file, so the
# linter reports each one as unused (SC2034) and notify() as uncalled
# (SC2329) — it cannot see across the `source` boundary the tests set up.
# Referencing them here is not linter appeasement: it is a real fixture check.
# A typo in one of these names would otherwise surface as a confusing unbound
# variable from deep inside the code under test, or worse, as a silently
# skipped assertion.
_t_cco_assert_fixture_complete() {
	local missing=""
	[[ -n $LOG_FILE ]] || missing+=" LOG_FILE"
	[[ -n $AUTO_CLOSE_TIMEOUT_MINUTES ]] || missing+=" AUTO_CLOSE_TIMEOUT_MINUTES"
	[[ -n $AUTO_CLOSE_WARNING_MINUTES ]] || missing+=" AUTO_CLOSE_WARNING_MINUTES"
	[[ ${#APPS[@]} -eq 3 ]] || missing+=" APPS"
	[[ ${#REAL_BINARIES[@]} -eq 3 ]] || missing+=" REAL_BINARIES"
	[[ ${#APP_TIMEOUT_MINUTES[@]} -eq 2 ]] || missing+=" APP_TIMEOUT_MINUTES"
	[[ ${#PROCESS_MATCH[@]} -eq 1 ]] || missing+=" PROCESS_MATCH"

	# Call notify() for real rather than probing it with `type -t`: block_app
	# routes every blocked launch through it, so a fixture whose notify is
	# broken would turn the notification assertions into silent no-ops. The
	# probe file is truncated afterwards so this call is not mistaken for one
	# made by the code under test.
	notify "fixture" "self-check"
	[[ -s "$TEST_TMPDIR/notifications" ]] || missing+=" notify"
	: >"$TEST_TMPDIR/notifications"

	if [[ -n $missing ]]; then
		printf 'harness fixture incomplete:%s\n' "$missing" >&2
		exit 1
	fi
}

_t_cco_teardown() {
	[[ -n ${TEST_TMPDIR:-} && -d ${TEST_TMPDIR} ]] && rm -rf "$TEST_TMPDIR"
}

_t_report() {
	printf '\n%s: %d passed, %d failed\n' "${1:-tests}" "$PASS" "$FAIL"
	[[ $FAIL -eq 0 ]]
}
