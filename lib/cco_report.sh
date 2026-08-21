#!/bin/bash
# Status reporting and reset commands for block_compulsive_opening.sh.
# Sourced by the entry script; inherits its strict mode and globals.

# Show status of all apps
show_status() {
	ensure_state_dir
	local current_hour
	current_hour=$(get_hour_key)

	echo "Compulsive Opening Blocker Status"
	echo "=================================="
	echo "Current hour: $current_hour"
	echo ""

	for app in "${!APPS[@]}"; do
		local state_file
		state_file=$(get_state_file "$app")
		local status="not opened this hour"
		local icon="○"

		if [[ -f $state_file ]]; then
			local last_hour
			last_hour=$(cat "$state_file" 2>/dev/null || echo "")
			if [[ $last_hour == "$current_hour" ]]; then
				status="already opened (blocked until next hour)"
				icon="●"
			else
				status="last opened: $last_hour"
			fi
		fi

		# Check if wrapped
		local wrapped="not installed"
		local wrapper_path="${APPS[$app]}"
		if [[ -f "${wrapper_path}.orig" ]]; then
			wrapped="wrapped"
		elif [[ -f $wrapper_path ]]; then
			wrapped="installed (not wrapped)"
		fi

		printf "  %s %-15s [%s] - %s\n" "$icon" "$app" "$wrapped" "$status"
	done

	echo ""
	echo "State directory: $STATE_DIR"
}

# Reset state for an app (allow opening again)
reset_app() {
	local app="$1"
	local state_file
	state_file=$(get_state_file "$app")

	if [[ -f $state_file ]]; then
		rm -f "$state_file"
		echo "Reset $app - can be opened again this hour"
		log_message "RESET: $app state cleared by user"
	else
		echo "$app was not marked as opened"
	fi
}

# Clear all state
reset_all() {
	ensure_state_dir
	rm -f "$STATE_DIR"/*.lastopen
	echo "All apps reset - can be opened again this hour"
	log_message "RESET: All app states cleared by user"
}

# Show usage
show_usage() {
	cat <<EOF
Block Compulsive Opening Script
================================

Limits messaging apps to one launch per hour to reduce compulsive checking.

Usage: $0 [command] [args]

Commands:
  install      - Install wrappers for all apps (requires root)
  uninstall    - Remove all wrappers (requires root)
  status       - Show current status of all apps
  reset <app>  - Reset an app to allow opening again this hour
  reset-all    - Reset all apps
  wrapper <app> [args] - Run as wrapper for an app (internal use)
  help         - Show this help message

Managed Apps:
  beeper         - Beeper messaging client
  signal-desktop - Signal messenger
  discord        - Discord chat

Examples:
  sudo $0 install     # Install all wrappers
  $0 status           # Check which apps were opened this hour
  $0 reset discord    # Allow Discord to be opened again

EOF
}
