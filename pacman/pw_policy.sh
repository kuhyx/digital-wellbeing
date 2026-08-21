#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Declared here rather than in the entry script: this is the only file that
# reads or writes them, and a cross-file global the sourcing script cannot
# see is a genuine SC2034 (the hook runs shellcheck without -x).
declare -a BLOCKED_KEYWORDS_LIST=()
declare -a WHITELISTED_NAMES_LIST=()
declare -a GREYLISTED_KEYWORDS_LIST=()
POLICY_LISTS_LOADED=0
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

	local script_dir
	script_dir="$(dirname "$(readlink -f "$0")")"
	local blocked_file="$script_dir/pacman_blocked_keywords.txt"
	local greylist_file="$script_dir/pacman_greylist.txt"
	local whitelist_file="$script_dir/pacman_whitelist.txt"

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

# shellcheck disable=SC2329 # invoked indirectly, see is_blocked_package_name/is_greylisted_package_name callers below
load_policy_lists() {
	if [[ $POLICY_LISTS_LOADED -eq 1 ]]; then
		return
	fi

	local script_dir
	script_dir="$(dirname "$(readlink -f "$0")")"
	local blocked_file="$script_dir/pacman_blocked_keywords.txt"
	local whitelist_file="$script_dir/pacman_whitelist.txt"
	local greylist_file="$script_dir/pacman_greylist.txt"

	read_policy_list_file() {
		local file_path="$1"
		local -n target_array="$2"
		local line=""

		target_array=()
		while IFS= read -r line || [[ -n $line ]]; do
			line="${line%$'\r'}"
			if [[ $line =~ ^[[:space:]]*(#|$) ]]; then
				continue
			fi
			target_array+=("${line,,}")
		done <"$file_path"
	}

	if [[ -f $blocked_file ]]; then
		read_policy_list_file "$blocked_file" BLOCKED_KEYWORDS_LIST
	else
		BLOCKED_KEYWORDS_LIST=()
		echo -e "${YELLOW}Warning:${NC} Missing blocked keywords file at $blocked_file" >&2
	fi

	if [[ -f $whitelist_file ]]; then
		read_policy_list_file "$whitelist_file" WHITELISTED_NAMES_LIST
	else
		WHITELISTED_NAMES_LIST=()
	fi

	if [[ -f $greylist_file ]]; then
		read_policy_list_file "$greylist_file" GREYLISTED_KEYWORDS_LIST
	else
		GREYLISTED_KEYWORDS_LIST=()
	fi

	POLICY_LISTS_LOADED=1
}

# Helper: strip a pacman package-file suffix (-<pkgver>-<pkgrel>-<arch>.pkg.tar.<ext>)
# down to the bare package name, if present. `pacman -U <path>` (what `yay`
# always uses to install a package it just built locally) passes a filename
# like "ungoogled-chromium-bin-150.0.7871.186-1-x86_64.pkg.tar.zst", not the
# bare name — without this, an exact-match whitelist entry for
# "ungoogled-chromium-bin" could never match a `-U` install and would always
# fall through to the (correctly still-substring) blocked-keywords check.
# Leaves package names without this suffix (the `-S` case) untouched.
# shellcheck disable=SC2329 # invoked indirectly by name (is_blocked_package_name)
function strip_pkgfile_suffix() {
	local name="$1"
	if [[ $name =~ ^(.+)-[^-]+-[0-9]+-(x86_64|any|i686|aarch64)\.pkg\.tar\.(zst|xz|gz|bz2|lrz|lzo|Z)$ ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
	else
		printf '%s' "$name"
	fi
}

# Helper: return 0 if the given package name is blocked by policy
# shellcheck disable=SC2329 # invoked indirectly by name (remove_installed_packages_matching, check_install_for)
function is_blocked_package_name() {
	load_policy_lists
	local normalized="${1,,}"
	local bare_name
	bare_name="$(strip_pkgfile_suffix "$normalized")"

	for allowed in "${WHITELISTED_NAMES_LIST[@]}"; do
		if [[ $normalized == "$allowed" || $bare_name == "$allowed" ]]; then
			return 1
		fi
	done

	for keyword in "${BLOCKED_KEYWORDS_LIST[@]}"; do
		if [[ $normalized == *"$keyword"* ]]; then
			return 0
		fi
	done

	return 1
}

# Helper: return 0 if the given package name is greylisted (challenge required)
# shellcheck disable=SC2329 # invoked indirectly by name (remove_installed_packages_matching, check_install_for)
function is_greylisted_package_name() {
	load_policy_lists
	local normalized="${1,,}"

	for keyword in "${GREYLISTED_KEYWORDS_LIST[@]}"; do
		if [[ $normalized == *"$keyword"* ]]; then
			return 0
		fi
	done

	return 1
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

# Function to check if user is trying to install packages that are always blocked
function check_for_always_blocked() {
	check_install_for is_blocked_package_name "$@"
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

function check_for_greylisted() {
	check_install_for is_greylisted_package_name "$@"
}
