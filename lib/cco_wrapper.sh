#!/bin/bash
# App-launch path for block_compulsive_opening.sh: the auto-close timer and the
# wrapper entry that the generated /usr/bin/<app> shims exec into.
# Sourced by the entry script; inherits its strict mode and globals.

# Launch app with auto-close timer
launch_with_timer() {
	local app="$1"
	local real_binary="$2"
	shift 2

	# $real_binary is what we EXEC; $proc_match is what we look for in the process
	# table. They are usually identical, but NOT when the exec target is a launcher
	# that exec()s away: discord's /usr/bin/discord.orig replaces itself with
	# ~/.config/discord/<app>/Discord, so matching/killing on the launcher path
	# would find nothing — the auto-close daemon would think the app exited
	# instantly and the time limit would silently never fire.
	local proc_match="${PROCESS_MATCH[$app]:-$real_binary}"

	# Check if auto-close is suspended for today
	if is_autoclose_suspended "$app"; then
		log_message "LAUNCHED: $app (auto-close suspended for today)"
		exec "$real_binary" "$@"
	fi

	# Use per-app timeout if set, otherwise fall back to global default
	local timeout_minutes="${APP_TIMEOUT_MINUTES[$app]:-$AUTO_CLOSE_TIMEOUT_MINUTES}"
	local warning_seconds=$(((timeout_minutes - AUTO_CLOSE_WARNING_MINUTES) * 60))
	local running_file
	running_file=$(get_running_file "$app")

	# Launch the app in background
	"$real_binary" "$@" &
	local app_pid=$!

	# Give Electron apps time to fork before we start polling
	sleep 2

	# Record state (FORK-FREE: use printf %s for timestamp)
	echo "$app_pid $(printf '%(%s)T' -1)" >"$running_file"
	log_message "LAUNCHED: $app with PID $app_pid (auto-close in ${timeout_minutes}m)"

	# Spawn the auto-close daemon in a completely detached subshell
	# Uses process-name matching so it works for Electron apps that fork on launch
	(
		# Detach from terminal
		exec </dev/null >/dev/null 2>&1

		# Wait for warning time
		sleep "$warning_seconds"

		# Check if still running before warning (by process name, not PID)
		if is_app_running "$proc_match"; then
			# Send warning notification
			notify-send -u critical -t 30000 "⏰ $app Closing Soon" \
				"Session will end in ${AUTO_CLOSE_WARNING_MINUTES} minutes. Save your work!" 2>/dev/null || true
		else
			# Process already exited
			rm -f "$running_file" 2>/dev/null || true
			exit 0
		fi

		# Wait remaining time
		sleep $((AUTO_CLOSE_WARNING_MINUTES * 60))

		# Check if still running (by process name)
		if is_app_running "$proc_match"; then
			# Send final notification
			notify-send -u critical -t 5000 "🚫 $app Session Ended" \
				"Time's up! Closing $app now." 2>/dev/null || true

			# Kill all matching processes (handles forked Electron children)
			kill_app "$proc_match"

			printf '%(%Y-%m-%d %H:%M:%S)T - AUTO-CLOSED: %s after %dm\n' -1 "$app" "${timeout_minutes}" >>"$LOG_FILE" 2>/dev/null || true
		fi

		rm -f "$running_file" 2>/dev/null || true
	) &
	disown

	# Wait for the app to exit by polling process name.
	# Electron apps fork immediately so waiting on $app_pid would return too soon.
	while is_app_running "$proc_match"; do
		sleep 5
	done

	# Clean up running state
	rm -f "$running_file" 2>/dev/null || true

	log_message "EXITED: $app"
}

# Main wrapper function - called when wrapping app launches
wrapper_main() {
	local app="$1"
	shift

	ensure_state_dir

	local real_binary
	if ! real_binary=$(get_real_binary "$app"); then
		log_message "ERROR: Real binary not found for $app"
		echo "Error: Real binary for $app not found. Was the installer run?" >&2
		exit 1
	fi

	# Clean up stale running state from previous crashes
	cleanup_stale_running_state "$app"

	if was_opened_this_hour "$app"; then
		block_app "$app"
		exit 1
	fi

	record_opening "$app"

	# Launch with auto-close timer (replaces direct exec)
	launch_with_timer "$app" "$real_binary" "$@"
}
