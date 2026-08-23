#!/bin/bash
# Date, time, uptime and boot-time helpers.
#
# Sourced by common.sh, which stays the single entry point every script
# sources -- 49 of them, so the public surface must not change.

# =============================================================================
# EFFICIENT TIME FUNCTIONS (zero-fork bash builtins)
# =============================================================================
# These functions use printf '%(...)'T' bash builtin (NO external commands)
# to avoid fork-storm anti-patterns in polling scripts.
# See: .github/skills/efficient-polling-scripts/SKILL.md

# Get current Unix timestamp (seconds since epoch)
# Usage: ts=$(get_timestamp)
# FORK-FREE: uses bash builtin printf %s (sec_since_epoch)
get_timestamp() {
	printf '%(%s)T' -1
}

# Get current date in YYYY-MM-DD format
# Usage: date=$(get_date)
get_date() {
	printf '%(%Y-%m-%d)T' -1
}

# Get current time in HH:MM:SS format
# Usage: time=$(get_time)
get_time() {
	printf '%(%H:%M:%S)T' -1
}

# Get current date-time in YYYY-MM-DD HH:MM:SS format
# Usage: dt=$(get_datetime)
get_datetime() {
	printf '%(%Y-%m-%d %H:%M:%S)T' -1
}

# Get day of week (1=Monday, 7=Sunday)
# Usage: dow=$(get_day_of_week)
get_day_of_week() {
	printf '%(%u)T' -1
}

# Get day name (Monday, Tuesday, ...)
# Usage: day=$(get_day_name)
get_day_name() {
	printf '%(%A)T' -1
}

# Get current hour (00-23)
# Usage: hour=$(get_hour)
get_hour() {
	printf '%(%H)T' -1
}

# Get current minute (00-59)
# Usage: minute=$(get_minute)
get_minute() {
	printf '%(%M)T' -1
}

# Get current second (00-59)
# Usage: second=$(get_second)
get_second() {
	printf '%(%S)T' -1
}

# Get Unix timestamp from boot (uptime in seconds)
# Usage: boot_seconds=$(get_uptime_seconds)
get_uptime_seconds() {
	read -r uptime_with_fraction _ </proc/uptime
	printf '%.*f\n' 0 "$uptime_with_fraction"
}

# Get boot time in YYYY-MM-DD HH:MM:SS format
# Usage: boot_time=$(get_boot_datetime)
# Calculates: current_time - uptime_seconds
get_boot_datetime() {
	local uptime_seconds
	uptime_seconds=$(get_uptime_seconds)
	local boot_ts=$(($(get_timestamp) - uptime_seconds))
	printf '%(%Y-%m-%d %H:%M:%S)T' "$boot_ts"
}

# Get boot time date only (YYYY-MM-DD)
# Usage: boot_date=$(get_boot_date)
get_boot_date() {
	local uptime_seconds
	uptime_seconds=$(get_uptime_seconds)
	local boot_ts=$(($(get_timestamp) - uptime_seconds))
	printf '%(%Y-%m-%d)T' "$boot_ts"
}

# Get boot time hour only (00-23)
# Usage: boot_hour=$(get_boot_hour)
get_boot_hour() {
	local uptime_seconds
	uptime_seconds=$(get_uptime_seconds)
	local boot_ts=$(($(get_timestamp) - uptime_seconds))
	printf '%(%H)T' "$boot_ts"
}

# Check if current time is within a given hour range
# Usage: if is_hour_in_range 5 8; then ...  # 5AM-8AM
is_hour_in_range() {
	local start_hour=$1
	local end_hour=$2
	local current_hour
	current_hour=$(get_hour)
	local current_hour_num=$((10#$current_hour))
	[[ $current_hour_num -ge $start_hour ]] && [[ $current_hour_num -lt $end_hour ]]
}

# Check if current day is a specific day of week
# Usage: if is_day_of_week 1 5 6 7; then ...  # Monday, Friday, Saturday, Sunday
is_day_of_week() {
	local target_day
	target_day=$(get_day_of_week)
	for day in "$@"; do
		[[ $target_day -eq $day ]] && return 0
	done
	return 1
}

# =============================================================================
# INTERACTIVE PROMPTS
# =============================================================================

# Ask yes/no question, returns 0 for yes, 1 for no
# Usage: if ask_yes_no "Continue?"; then ...
ask_yes_no() {
	local prompt="$1"
	local ans
	read -r -p "$prompt [y/N]: " ans || true
	case "${ans:-}" in
	y | Y | yes | YES) return 0 ;;
	*) return 1 ;;
	esac
}

# Check if a command is available
# Usage: if has_cmd git; then ...
has_cmd() {
	command -v "$1" >/dev/null 2>&1
}

# =============================================================================
# STANDARD SETUP HEADER
# =============================================================================

# Print a standard setup header for scripts
# Usage: print_setup_header "Script Name"
print_setup_header() {
	local title="$1"
	local current_datetime
	current_datetime=$(get_datetime)
	echo "$title"
	printf '=%.0s' $(seq 1 ${#title})
	echo ""
	echo "Current Date: $current_datetime"
	echo "User: $USER"
	echo "Original user: $(get_actual_user)"
	if [[ $INTERACTIVE_MODE == "true" ]]; then
		echo "Mode: Interactive (prompts enabled)"
	else
		echo "Mode: Automatic (auto-yes, use --interactive for prompts)"
	fi
}

# =============================================================================
# MOUNT/UNMOUNT HELPERS (for hosts guard and similar)
# =============================================================================

# Count mount layers for a path
# Usage: count=$(mount_layers_count "/etc/hosts")
mount_layers_count() {
	local target="$1"
	awk -v t="$target" '$5==t{c++} END{print c+0}' /proc/self/mountinfo 2>/dev/null || echo 0
}

# Collapse all bind mount layers for a path
# Usage: collapse_mounts "/etc/hosts" [max_iterations]
collapse_mounts() {
	local target="$1"
	local max_iter="${2:-20}"
	local i=0

	if has_cmd mountpoint; then
		while mountpoint -q "$target"; do
			umount -l "$target" >/dev/null 2>&1 || break
			i=$((i + 1))
			((i >= max_iter)) && break
		done
	else
		local cnt
		cnt=$(mount_layers_count "$target")
		while ((cnt > 1)); do
			umount -l "$target" >/dev/null 2>&1 || break
			i=$((i + 1))
			((i >= max_iter)) && break
			cnt=$(mount_layers_count "$target")
		done
	fi
}

# =============================================================================
# RESOLUTION/FORMAT VALIDATION
# =============================================================================

# Validate resolution format (WIDTHxHEIGHT)
# Usage: if validate_resolution "1920x1080"; then ...
validate_resolution() {
	local res="$1"
	[[ $res =~ ^[0-9]+x[0-9]+$ ]]
}

# Generate output filename with suffix
# Usage: output=$(generate_output_filename "input.jpg" "_resized")
generate_output_filename() {
	local input="$1"
	local suffix="$2"
	local ext="${3:-}"

	local basename dirname filename extension
	basename=$(basename "$input")
	dirname=$(dirname "$input")
	filename="${basename%.*}"
	extension="${basename##*.}"

	# Handle files without extension
	if [[ $filename == "$extension" ]]; then
		extension="${ext:-jpg}"
	fi

	echo "${dirname}/${filename}${suffix}.${extension}"
}
