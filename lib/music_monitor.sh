#!/bin/bash
# The two monitoring loops: the instant (adaptive-interval) loop and the
# fixed-interval fallback loop.
#
# Sourced by music_parallelism.sh; split out to keep it under the 250-line cap.
# Sourced rather than run, so it inherits the caller's strict mode and calls
# the detection helpers in music_detect.sh, which the entry sources first.

# Send notification to user
notify_user() {
	local focus_app="$1"
	local message="Music stopped - focus mode active ($focus_app detected)"

	# Try to send desktop notification
	if command -v notify-send &>/dev/null; then
		notify-send -u normal -t 5000 "🎵 Music Parallelism" "$message" 2>/dev/null || true
	fi

	log_message "$message"
}

# Instant monitoring loop - uses polling at high frequency ONLY when focus app is detected
# When focus app active: checks every 0.5s. When idle: checks every 3s. Reduces fork overhead.
# OPTIMIZATION: Single batched pgrep call instead of multiple separate calls
instant_monitor_loop() {
	local next_enforcement_ts=0
	local current_ts=0
	local focus_app=""
	local sleep_interval="$IDLE_CHECK_INTERVAL"

	log_message "=== Music Parallelism INSTANT Monitor Started ==="
	log_message "Focus apps (windows): ${FOCUS_APPS_WINDOWS[*]}"
	log_message "Focus apps (processes): ${FOCUS_APPS_PROCESSES[*]}"
	log_message "Polling: ${FAST_CHECK_INTERVAL}s active, ${ACTIVE_NO_MUSIC_INTERVAL}s stable-focus, ${IDLE_CHECK_INTERVAL}s idle, ${ENFORCEMENT_COOLDOWN}s enforcement cooldown"

	while true; do
		if focus_app=$(is_focus_app_running 2>/dev/null); then
			current_ts=$(get_timestamp)
			if ((current_ts >= next_enforcement_ts)); then
				if find_music_services >/dev/null 2>&1; then
					if kill_music_services 1; then
						notify_user "$focus_app"
						log_message "INSTANT KILL: Music services terminated"
						sleep_interval="$ACTIVE_AFTER_KILL_INTERVAL"
					fi
				else
					sleep_interval="$ACTIVE_NO_MUSIC_INTERVAL"
				fi
				next_enforcement_ts=$((current_ts + ENFORCEMENT_COOLDOWN))
			else
				sleep_interval="$ACTIVE_NO_MUSIC_INTERVAL"
			fi
		else
			next_enforcement_ts=0
			sleep_interval="$IDLE_CHECK_INTERVAL"
		fi

		wait_seconds "$sleep_interval"
	done
}

# Main monitoring loop
monitor_loop() {
	log_message "=== Music Parallelism Monitor Started ==="
	log_message "Focus apps (windows): ${FOCUS_APPS_WINDOWS[*]}"
	log_message "Focus apps (processes): ${FOCUS_APPS_PROCESSES[*]}"
	log_message "Music services monitored: ${MUSIC_SERVICES[*]}"
	log_message "Check interval: ${CHECK_INTERVAL}s"

	while true; do
		# Check if a focus app is running
		local focus_app
		if focus_app=$(is_focus_app_running); then
			# Focus app detected, check for music services
			# Named to avoid colliding with the MUSIC_SERVICES config array,
			# which this file also reads.
			local active_services
			if active_services=$(find_music_services); then
				log_message "Conflict detected: Focus app '$focus_app' running with music services"
				log_message "Active music services: $active_services"

				# Kill the music services
				if kill_music_services 1; then
					notify_user "$focus_app"
				fi
			fi
		fi

		wait_seconds "$CHECK_INTERVAL"
	done
}
