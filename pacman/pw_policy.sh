#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Declared here rather than in the entry script: this is the only file that
# reads them, and a cross-file global the sourcing script cannot see is a
# genuine SC2034 (the hook runs shellcheck without -x).
INTEGRITY_DIR="/var/lib/pacman-wrapper"
INTEGRITY_FILE="${INTEGRITY_DIR}/policy.sha256"

# Verify integrity of policy files
verify_policy_integrity() {
	if [[ ! -f $INTEGRITY_FILE ]]; then
		echo -e "${RED}SECURITY WARNING: Policy integrity file missing!${NC}" >&2
		echo -e "${RED}The pacman wrapper may have been tampered with.${NC}" >&2
		echo -e "${RED}Please reinstall the wrapper using: sudo install_pacman_wrapper.sh${NC}" >&2
		return 1
	fi

	# Verify checksums
	local failed=0
	while IFS= read -r line; do
		local expected_hash expected_file
		expected_hash=$(echo "$line" | awk '{print $1}')
		expected_file=$(echo "$line" | awk '{print $2}')

		if [[ -f $expected_file ]]; then
			local actual_hash
			actual_hash=$(sha256sum "$expected_file" 2>/dev/null | awk '{print $1}')
			if [[ $actual_hash != "$expected_hash" ]]; then
				echo -e "${RED}SECURITY WARNING: Policy file integrity check failed for $expected_file${NC}" >&2
				failed=1
			fi
		fi
	done <"$INTEGRITY_FILE"

	if [[ $failed -eq 1 ]]; then
		echo -e "${RED}CRITICAL: Policy files have been tampered with!${NC}" >&2
		echo -e "${RED}This could be an attempt to bypass security restrictions.${NC}" >&2
		echo -e "${RED}Wrapper operation DENIED. Please reinstall using: sudo install_pacman_wrapper.sh${NC}" >&2
		return 1
	fi

	return 0
}

# Helper: Check if this is an install command and run a filter on each package name
# Usage: check_install_for filter_func "$@"
# Returns 0 if filter_func matches any package
function check_install_for() {
	local filter_func="$1"
	shift
	# Check if the command is an installation command
	if [[ ${1:-} == "-S" || ${1:-} == "-Sy" || ${1:-} == "-Syu" || ${1:-} == "-Syyu" || ${1:-} == "-U" ]]; then
		for arg in "$@"; do
			# Strip repository prefix if present (like extra/ or community/)
			local package_name="${arg##*/}"
			if "$filter_func" "$package_name"; then
				return 0
			fi
		done
	fi
	return 1
}

# Helper to check if a package name is steam
# shellcheck disable=SC2329 # invoked indirectly by name (check_install_for)
function is_steam_package() {
	[[ $1 == "steam" ]]
}

# Function to check if user is trying to install steam (challenge-eligible package)
function check_for_steam() {
	check_install_for is_steam_package "$@"
}

