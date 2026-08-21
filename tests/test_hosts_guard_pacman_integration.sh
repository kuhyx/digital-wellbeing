#!/bin/bash
# Regression tests for pacman wrapper / guard-lib hosts-guard fallback integration.
#
# The pre-guard-lib hooks this test used to check (pacman-pre-unlock-hosts.sh,
# pacman-post-relock-hosts.sh, hosts-guard-common.sh, install_pacman_hooks.sh)
# were archived to testsAndMisc-archive once guard-lib's generic pacman hooks
# (10-guard-lib-unlock-all.hook / 90-guard-lib-relock-all.hook) fully replaced
# them -- see docs/superpowers/evidence/archive-setup-hosts-guard-2026-08-18.json.
# Only pacman_wrapper.sh's guard-lib-aware fallback logic remains to check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WRAPPER_FILE="$REPO_DIR/scripts/periodic_background/digital_wellbeing/pacman/pacman_wrapper.sh"
# The wrapper was split into flat pw_*.sh libs under the 250-line cap, so a
# function-definition check has to search the entry script AND its libs.
# Grepping the entry script alone reports "not found" for code that simply
# moved one file over. The call-site ORDER assertions below still target the
# entry script, where the calls themselves remain.
WRAPPER_SOURCES=("$WRAPPER_FILE")
for _pw_lib in "$(dirname "$WRAPPER_FILE")"/pw_*.sh; do
	[[ -f "$_pw_lib" ]] && WRAPPER_SOURCES+=("$_pw_lib")
done

assert_contains() {
	local file_path="$1"
	local pattern="$2"
	local message="$3"

	if grep -Fq "$pattern" "$file_path" "${WRAPPER_SOURCES[@]:1}"; then
		echo "PASS: $message"
	else
		echo "FAIL: $message"
		exit 1
	fi
}

first_line_number() {
	local file_path="$1"
	local pattern="$2"

	grep -n -F -m 1 "$pattern" "$file_path" | cut -d: -f1
}

assert_order() {
	local file_path="$1"
	local first_pattern="$2"
	local second_pattern="$3"
	local message="$4"
	local first_line
	local second_line

	first_line="$(first_line_number "$file_path" "$first_pattern")"
	second_line="$(first_line_number "$file_path" "$second_pattern")"

	if [[ -z "$first_line" || -z "$second_line" ]]; then
		echo "FAIL: $message"
		exit 1
	fi

	if ((first_line < second_line)); then
		echo "PASS: $message"
	else
		echo "FAIL: $message"
		exit 1
	fi
}

echo "=== Hosts guard pacman integration regression tests ==="

bash -n "$WRAPPER_FILE"
echo "PASS: shell syntax is valid"

assert_contains "$WRAPPER_FILE" 'pacman_hooks_manage_guard_lib()' \
	"wrapper detects when guard-lib's pacman hooks are installed"
assert_contains "$WRAPPER_FILE" 'should_use_wrapper_guard_lib_fallback()' \
	"wrapper exposes a dedicated fallback path for hosts guard"
assert_order "$WRAPPER_FILE" 'if ! check_and_handle_db_lock "$@"; then' 'if should_use_wrapper_guard_lib_fallback "$@"; then' \
	"wrapper checks pacman db lock before any manual hosts unlock fallback"
assert_contains "$WRAPPER_FILE" 'manual_guard_lib_fallback=1' \
	"wrapper tracks whether manual hosts guard fallback was used"
assert_contains "$WRAPPER_FILE" '/etc/pacman.d/hooks/10-guard-lib-unlock-all.hook' \
	"wrapper's guard-lib detection checks the generic unlock-all hook"
assert_contains "$WRAPPER_FILE" '/etc/pacman.d/hooks/90-guard-lib-relock-all.hook' \
	"wrapper's guard-lib detection checks the generic relock-all hook"

echo "All hosts guard pacman integration regression tests passed."
