#!/bin/bash
# Common library functions for linux-configuration scripts
# Source this file at the beginning of scripts that need shared functionality
#
# Usage: source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
# Or:    source "/path/to/lib/common.sh"

# Prevent multiple sourcing
[[ -n ${_LIB_COMMON_LOADED:-} ]] && return 0
_LIB_COMMON_LOADED=1

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Log message with timestamp to stderr and optionally to a file
# Usage: log_message "message" [log_file]
log_message() {
	local msg="$1"
	local log_file="${2:-}"
	local formatted
	printf -v formatted '%(%Y-%m-%d %H:%M:%S)T - %s' -1 "$msg"
	echo "$formatted" >&2
	if [[ -n $log_file ]]; then
		echo "$formatted" >>"$log_file" 2>/dev/null || true
	fi
}

# Simple log with timestamp (no file output)
# Usage: log "message"
log() {
	local _ts
	printf -v _ts '%(%Y-%m-%d %H:%M:%S)T' -1
	printf '[%s] %s\n' "$_ts" "$*"
}

# =============================================================================
# SUDO / ROOT HANDLING
# =============================================================================

# Check if running as root, if not re-exec with sudo
# Usage: require_root "$@"
require_root() {
	if [[ $EUID -ne 0 ]]; then
		echo "This script requires root privileges."
		echo "Requesting sudo access..."
		exec sudo "$0" "$@"
	fi
}

# Get the actual user even when running with sudo
# Usage: ACTUAL_USER=$(get_actual_user)
get_actual_user() {
	echo "${SUDO_USER:-$USER}"
}

# Get the actual user's home directory
# Usage: USER_HOME=$(get_actual_user_home)
get_actual_user_home() {
	local user
	user=$(get_actual_user)
	if [[ $user == "root" ]]; then
		echo "/root"
	else
		echo "/home/$user"
	fi
}

# Set both ACTUAL_USER and USER_HOME variables (common pattern)
# Usage: set_actual_user_vars
#        echo "$ACTUAL_USER"   # => the actual user
#        echo "$USER_HOME"     # => /home/username
set_actual_user_vars() {
	ACTUAL_USER=$(get_actual_user)
	USER_HOME=$(get_actual_user_home)
	export ACTUAL_USER USER_HOME
}

# =============================================================================
# ARGUMENT PARSING HELPERS
# =============================================================================

# Parse common --interactive/-i and --help/-h flags
# Sets INTERACTIVE_MODE variable (exported for use by calling scripts)
# Usage: parse_common_args "$@"
#        shift "$COMMON_ARGS_SHIFT"
export INTERACTIVE_MODE=false
export COMMON_ARGS_SHIFT=0

parse_interactive_args() {
	INTERACTIVE_MODE=false
	COMMON_ARGS_SHIFT=0
	local script_name="${0##*/}"

	while [[ $# -gt 0 ]]; do
		case $1 in
		-i | --interactive)
			INTERACTIVE_MODE=true
			((COMMON_ARGS_SHIFT++))
			shift
			;;
		-h | --help)
			echo "Usage: $script_name [OPTIONS]"
			echo "Options:"
			echo "  -i, --interactive    Enable interactive prompts (default: auto-yes)"
			echo "  -h, --help          Show this help message"
			exit 0
			;;
		*)
			# Stop parsing at first unknown argument
			break
			;;
		esac
	done
}

# Handle common argument patterns for scripts with custom usage functions
# Usage: handle_arg_help_or_unknown "$1" usage_function err_function
# Returns: 1 if the argument is not ours, so the caller handles it.
# Exits: on -h/--help (exit 0) or unknown arg starting with - (exit 2).
# There is deliberately no success return: every other branch exits. The old
# trailing `return 0` was unreachable, and the doc promised a 0 that no code
# path could ever produce.
handle_arg_help_or_unknown() {
	local arg="$1"
	local usage_fn="${2:-usage}"
	local err_fn="${3:-err}"

	case "$arg" in
	-h | --help)
		"$usage_fn"
		exit 0
		;;
	-*)
		"$err_fn" "Unknown argument: $arg"
		"$usage_fn"
		exit 2
		;;
	*)
		return 1 # Not a flag, let caller handle it
		;;
	esac
}

# Initialize a setup script with common boilerplate
# Usage: init_setup_script "Script Title" "$@"
# This combines: parse_interactive_args, shift, require_root, print_setup_header
init_setup_script() {
	local title="$1"
	shift
	parse_interactive_args "$@"
	shift "$COMMON_ARGS_SHIFT"
	require_root "$@"
	print_setup_header "$title"
}

_COMMON_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=common_services.sh
source "$_COMMON_DIR/common_packages.sh"
# shellcheck source=common_services.sh
source "$_COMMON_DIR/common_services.sh"
# shellcheck source=common_datetime.sh
source "$_COMMON_DIR/common_datetime.sh"
