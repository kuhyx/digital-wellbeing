#!/bin/bash
# State, timing and process helpers for block_compulsive_opening.sh.
# Sourced by the entry script; inherits its strict mode, its notify() helper
# and the STATE_DIR/LOG_FILE/APPS/REAL_BINARIES/PROCESS_MATCH globals it
# defines.

# Ensure state directory exists
ensure_state_dir() {
	mkdir -p "$STATE_DIR" 2>/dev/null || true
}

# Log message with timestamp
log_message() {
	local msg
	msg="$(printf '%(%Y-%m-%d %H:%M:%S)T' -1) - $1"
	echo "$msg" >&2
	echo "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

# Get current hour key (YYYY-MM-DD-HH format)
get_hour_key() {
	printf '%(%Y-%m-%d-%H)T' -1
}

# Get state file path for an app
get_state_file() {
	local app="$1"
	echo "$STATE_DIR/${app}.lastopen"
}

# Check if app was already opened this hour
was_opened_this_hour() {
	local app="$1"
	local state_file
	state_file=$(get_state_file "$app")
	local current_hour
	current_hour=$(get_hour_key)

	if [[ -f $state_file ]]; then
		local last_hour
		last_hour=$(cat "$state_file" 2>/dev/null || echo "")
		if [[ $last_hour == "$current_hour" ]]; then
			return 0 # Was opened this hour
		fi
	fi
	return 1 # Not opened this hour
}

# Record app opening
record_opening() {
	local app="$1"
	local state_file
	state_file=$(get_state_file "$app")
	local current_hour
	current_hour=$(get_hour_key)

	echo "$current_hour" >"$state_file"
	log_message "ALLOWED: $app opened (first time this hour: $current_hour)"
}

# Block app and notify
block_app() {
	local app="$1"
	local current_hour
	current_hour=$(get_hour_key)

	log_message "BLOCKED: $app launch prevented (already opened this hour: $current_hour)"

	# Send notification using common library
	notify "🚫 $app Blocked" "Already opened this hour. Wait until the next hour." critical 5000
}

# Get real binary path for an app
get_real_binary() {
	local app="$1"
	local wrapper_path="${APPS[$app]}"
	local real_binary="${REAL_BINARIES[$app]}"

	# Check if wrapper is installed (original moved to .orig)
	if [[ -f "${wrapper_path}.orig" ]]; then
		# Wrapper installed, return the actual executable
		echo "$real_binary"
		return 0
	fi

	return 1
}

# Get running state file path for an app (tracks PID and start time)
get_running_file() {
	local app="$1"
	echo "$STATE_DIR/${app}.running"
}

# Clean up stale running state (process no longer running)
# Uses process-name matching so Electron apps that fork don't appear stale.
cleanup_stale_running_state() {
	local app="$1"
	local running_file
	running_file=$(get_running_file "$app")

	if [[ ! -f $running_file ]]; then
		return 0
	fi

	# Match on PROCESS_MATCH when the exec target is a launcher that exec()s away
	# (see the PROCESS_MATCH map); otherwise the exec target is the process.
	local real_binary="${PROCESS_MATCH[$app]:-${REAL_BINARIES[$app]}}"

	# Check if any process matching the real binary is still running
	if ! is_app_running "$real_binary"; then
		log_message "CLEANUP: Stale running state for $app (no matching processes found)"
		rm -f "$running_file"
	fi
}

# Check if app is running by process name (handles Electron apps that fork)
is_app_running() {
	local real_binary="$1"
	pgrep -f "$real_binary" >/dev/null 2>&1
}

# Kill all processes matching the real binary path
kill_app() {
	local real_binary="$1"
	pkill -f "$real_binary" 2>/dev/null || true
	sleep 2
	pkill -9 -f "$real_binary" 2>/dev/null || true
}

# Check if auto-close is suspended for an app today
is_autoclose_suspended() {
	local app="$1"
	local today
	today=$(printf '%(%Y-%m-%d)T' -1)
	local suspend_file="$STATE_DIR/${app}.suspend-autoclose"

	if [[ -f $suspend_file ]]; then
		local suspend_date
		suspend_date=$(cat "$suspend_file" 2>/dev/null || echo "")
		if [[ $suspend_date == "$today" ]]; then
			return 0 # Suspended for today
		else
			# Stale suspend file, clean up
			rm -f "$suspend_file"
		fi
	fi
	return 1
}
