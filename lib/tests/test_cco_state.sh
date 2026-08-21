#!/usr/bin/env bash
# Covers lib/cco_state.sh — the logic that decides whether a launch is allowed.
#
# This is the whole point of the tool: was_opened_this_hour deciding wrong in
# either direction is the failure that matters. Too permissive and the blocker
# does nothing; too strict and a legitimately-closed app can never be reopened.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cco_harness.sh
. "$HERE/cco_harness.sh"
# shellcheck source=../cco_state.sh
. "$CCO_LIB_DIR/cco_state.sh"

_t_cco_setup
trap _t_cco_teardown EXIT

printf 'get_hour_key: a stable YYYY-MM-DD-HH stamp\n'
hour="$(get_hour_key)"
if [[ $hour =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
	_t_pass "the hour key is YYYY-MM-DD-HH"
else
	_t_fail "the hour key is YYYY-MM-DD-HH (got '$hour')"
fi
_t_eq "$hour" "$(get_hour_key)" "two calls in the same hour agree"

printf '\nget_state_file: one file per app, under STATE_DIR\n'
_t_eq "$STATE_DIR/discord.lastopen" "$(get_state_file discord)" "the state path is derived from the app name"
_t_eq "$STATE_DIR/discord.running" "$(get_running_file discord)" "the running-state path is separate from the lastopen path"

printf '\nwas_opened_this_hour: the core allow/block decision\n'
rm -f "$STATE_DIR/discord.lastopen"
if was_opened_this_hour discord; then
	_t_fail "a fresh app is not yet opened this hour"
else
	_t_pass "a fresh app is not yet opened this hour"
fi

record_opening discord >/dev/null 2>&1
if was_opened_this_hour discord; then
	_t_pass "after record_opening the app counts as opened"
else
	_t_fail "after record_opening the app counts as opened"
fi

printf '\nwas_opened_this_hour: a stale hour must NOT keep blocking\n'
# The bug that would matter most: if a previous hour's stamp still blocked, an
# app could never be reopened. Write a deliberately old stamp.
echo "2000-01-01-00" >"$STATE_DIR/discord.lastopen"
if was_opened_this_hour discord; then
	_t_fail "a previous hour's stamp must not block the current hour"
else
	_t_pass "a previous hour's stamp does not block the current hour"
fi

printf '\nwas_opened_this_hour: an unreadable/empty stamp allows the launch\n'
: >"$STATE_DIR/discord.lastopen"
if was_opened_this_hour discord; then
	_t_fail "an empty state file must not block"
else
	_t_pass "an empty state file does not block"
fi

printf '\nrecord_opening: writes exactly the current hour\n'
rm -f "$STATE_DIR/beeper.lastopen"
record_opening beeper >/dev/null 2>&1
_t_eq "$(get_hour_key)" "$(cat "$STATE_DIR/beeper.lastopen")" "the stamp written is the current hour key"

printf '\nblock_app: notifies the user\n'
: >"$TEST_TMPDIR/notifications"
block_app discord >/dev/null 2>&1
_t_has "$(cat "$TEST_TMPDIR/notifications")" "Blocked" "blocking sends a desktop notification"

printf '\nis_autoclose_suspended: only todays marker counts\n'
rm -f "$STATE_DIR/discord.suspend-autoclose"
if is_autoclose_suspended discord; then
	_t_fail "no marker means not suspended"
else
	_t_pass "no marker means not suspended"
fi

printf '%(%Y-%m-%d)T' -1 >"$STATE_DIR/discord.suspend-autoclose"
if is_autoclose_suspended discord; then
	_t_pass "todays marker suspends auto-close"
else
	_t_fail "todays marker suspends auto-close"
fi

echo "1999-12-31" >"$STATE_DIR/discord.suspend-autoclose"
if is_autoclose_suspended discord; then
	_t_fail "a stale marker must not suspend auto-close"
else
	_t_pass "a stale marker does not suspend auto-close"
fi
if [[ -f "$STATE_DIR/discord.suspend-autoclose" ]]; then
	_t_fail "a stale marker is cleaned up on detection"
else
	_t_pass "a stale marker is cleaned up on detection"
fi

printf '\nget_real_binary: only reports a binary once the wrapper is installed\n'
rm -f "$TEST_TMPDIR/bin/beeper.orig"
if get_real_binary beeper >/dev/null 2>&1; then
	_t_fail "an unwrapped app reports no real binary"
else
	_t_pass "an unwrapped app reports no real binary"
fi

: >"$TEST_TMPDIR/bin/beeper.orig"
_t_eq "$TEST_TMPDIR/real/beepertexts" "$(get_real_binary beeper)" "a wrapped app resolves to its real binary"

printf '\nlog_message: appends to the log and echoes to stderr\n'
: >"$LOG_FILE"
log_message "hello from the test" 2>/dev/null
_t_has "$(cat "$LOG_FILE")" "hello from the test" "the message reaches the log file"

printf '\nensure_state_dir: creates STATE_DIR when it is missing\n'
rm -rf "$STATE_DIR"
ensure_state_dir
if [[ -d $STATE_DIR ]]; then
	_t_pass "a missing state directory is created"
else
	_t_fail "a missing state directory is created"
fi
# Idempotent: the real script calls it on every wrapper launch.
ensure_state_dir
_t_pass "calling it again on an existing directory is harmless"

printf '\ncleanup_stale_running_state: clears state when nothing is running\n'
running="$(get_running_file discord)"
echo "999999 123" >"$running"
# PROCESS_MATCH points at a path no process can match, so this is the
# "app already exited" case.
cleanup_stale_running_state discord 2>/dev/null
if [[ -f $running ]]; then
	_t_fail "a running-state file for a dead process is removed"
else
	_t_pass "a running-state file for a dead process is removed"
fi

printf '\ncleanup_stale_running_state: no running file is a no-op\n'
# The early return. It must not fall through to the pgrep path, which on a
# machine where the app IS running would otherwise be consulted for nothing.
rm -f "$running"
if (cleanup_stale_running_state discord); then
	_t_pass "a missing running-state file returns success without probing"
else
	_t_fail "a missing running-state file returns success without probing"
fi

_t_report "test_cco_state"
