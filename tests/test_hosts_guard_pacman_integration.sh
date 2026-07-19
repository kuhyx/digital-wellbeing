#!/bin/bash
# Regression tests for pacman wrapper and hosts-guard hook integration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WRAPPER_FILE="$REPO_DIR/scripts/periodic_background/digital_wellbeing/pacman/pacman_wrapper.sh"
PRE_HOOK_FILE="$REPO_DIR/scripts/periodic_background/hosts/guard/pacman-hooks/pacman-pre-unlock-hosts.sh"
POST_HOOK_FILE="$REPO_DIR/scripts/periodic_background/hosts/guard/pacman-hooks/pacman-post-relock-hosts.sh"
COMMON_FILE="$REPO_DIR/scripts/periodic_background/hosts/guard/pacman-hooks/hosts-guard-common.sh"
INSTALLER_FILE="$REPO_DIR/scripts/periodic_background/hosts/guard/install_pacman_hooks.sh"

assert_contains() {
	local file_path="$1"
	local pattern="$2"
	local message="$3"

	if grep -Fq "$pattern" "$file_path"; then
		echo "PASS: $message"
	else
		echo "FAIL: $message"
		exit 1
	fi
}

assert_not_regex() {
	local file_path="$1"
	local pattern="$2"
	local message="$3"

	if grep -Eq "$pattern" "$file_path"; then
		echo "FAIL: $message"
		exit 1
	fi

	echo "PASS: $message"
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

	if (( first_line < second_line )); then
		echo "PASS: $message"
	else
		echo "FAIL: $message"
		exit 1
	fi
}

echo "=== Hosts guard pacman integration regression tests ==="

for file_path in "$WRAPPER_FILE" "$PRE_HOOK_FILE" "$POST_HOOK_FILE" "$COMMON_FILE" "$INSTALLER_FILE"; do
	bash -n "$file_path"
done
echo "PASS: shell syntax is valid"

assert_not_regex "$PRE_HOOK_FILE" '(^|[[:space:]])(sudo[[:space:]]+)?rm[[:space:]]+/etc/hosts([[:space:]]|$)' \
	"pre-transaction hook must not delete /etc/hosts"

assert_contains "$WRAPPER_FILE" 'pacman_hooks_manage_hosts_guard()' \
	"wrapper detects when pacman hooks already manage hosts guard"
assert_contains "$WRAPPER_FILE" 'should_use_wrapper_hosts_guard_fallback()' \
	"wrapper exposes a dedicated fallback path for hosts guard"
assert_order "$WRAPPER_FILE" 'if ! check_and_handle_db_lock "$@"; then' 'if should_use_wrapper_hosts_guard_fallback "$@"; then' \
	"wrapper checks pacman db lock before any manual hosts unlock fallback"
assert_contains "$WRAPPER_FILE" 'manual_hosts_guard=1' \
	"wrapper tracks whether manual hosts guard fallback was used"

assert_contains "$INSTALLER_FILE" 'install -m 755 "$SCRIPT_DIR/pacman-hooks/hosts-guard-common.sh" /usr/local/share/hosts-guard/' \
	"installer deploys shared hosts guard hook helpers"

echo "All hosts guard pacman integration regression tests passed."
