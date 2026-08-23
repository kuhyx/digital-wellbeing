#!/bin/bash
# Service control, directory helpers and the log_* family.
#
# Sourced by common.sh, which stays the single entry point every script
# sources -- 49 of them, so the public surface must not change.

# =============================================================================
# FILE/PATH UTILITIES
# =============================================================================

# Get the directory containing the calling script
# Usage: SCRIPT_DIR=$(get_script_dir)
get_script_dir() {
	dirname "$(readlink -f "${BASH_SOURCE[1]:-$0}")"
}

# Ensure a directory exists
# Usage: ensure_dir "/path/to/dir"
ensure_dir() {
	local dir="$1"
	if [[ ! -d $dir ]]; then
		mkdir -p "$dir"
	fi
}

# =============================================================================
# SYSTEMD HELPERS
# =============================================================================

# Internal helper for running systemctl with optional --user flag
_systemctl_cmd() {
	local user_flag="$1"
	shift
	if [[ $user_flag == "--user" ]]; then
		systemctl --user "$@"
	else
		systemctl "$@"
	fi
}

# Enable and start a systemd service (user or system)
# Usage: enable_service "service-name" [--user]
enable_service() {
	local service="$1"
	local user_flag="${2:-}"
	_systemctl_cmd "$user_flag" daemon-reload
	_systemctl_cmd "$user_flag" enable --now "$service"
}

# Check if a systemd service is active
# Usage: if is_service_active "service-name" [--user]; then ...
is_service_active() {
	_systemctl_cmd "${2:-}" is-active --quiet "$1"
}

# Check if a systemd service is enabled
# Usage: if is_service_enabled "service-name" [--user]; then ...
is_service_enabled() {
	_systemctl_cmd "${2:-}" is-enabled --quiet "$1" 2>/dev/null
}

# =============================================================================
# COLORED LOGGING (for scripts that need colored output)
# =============================================================================

# ANSI color codes
declare -g COLOR_RED='\033[1;31m'
declare -g COLOR_GREEN='\033[1;32m'
declare -g COLOR_YELLOW='\033[1;33m'
declare -g COLOR_BLUE='\033[1;34m'
declare -g COLOR_NC='\033[0m'

log_info() {
	printf "${COLOR_BLUE}[INFO]${COLOR_NC} %s\n" "$*"
}

log_ok() {
	printf "${COLOR_GREEN}[ OK ]${COLOR_NC} %s\n" "$*"
}

log_warn() {
	printf "${COLOR_YELLOW}[WARN]${COLOR_NC} %s\n" "$*" >&2
}

log_error() {
	printf "${COLOR_RED}[ERROR]${COLOR_NC} %s\n" "$*" >&2
}

# Alias for compatibility
warn() { log_warn "$@"; }
err() { log_error "$@"; }
