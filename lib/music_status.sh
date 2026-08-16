#!/bin/bash
# The status report and the usage text.
#
# Sourced by music_parallelism.sh; split out to keep it under the 250-line cap.
# Sourced rather than run, so it inherits the caller's strict mode and reads
# the interval and MUSIC_* configuration set above the source line.

# Show status
show_status() {
	echo "Music Parallelism Monitor Status"
	echo "================================="
	echo ""

	echo "Focus Applications (window-based detection):"
	local focus_running=false

	# Check windows (OPTIMIZED: single xdotool call with combined regex)
	if command -v xdotool &>/dev/null && [[ ${#FOCUS_APPS_WINDOWS[@]} -gt 0 ]]; then
		local regex
		printf -v regex '%s|' "${FOCUS_APPS_WINDOWS[@]}"
		regex="${regex%|}" # strip trailing |
		if xdotool search --name "$regex" &>/dev/null 2>&1; then
			echo "  ✓ Focus window detected"
			focus_running=true
		fi
	fi

	# Check processes using shared /proc-based helper (fork-free)
	if is_focus_app_running >/dev/null 2>&1; then
		echo "  ✓ Focus process running"
		focus_running=true
	fi

	if ! $focus_running; then
		echo "  (none detected)"
	fi

	echo ""
	echo "Music Services:"
	local music_running=false
	if music_services=$(find_music_services 2>/dev/null); then
		echo "$music_services" | while read -r svc; do
			echo "  ♪ $svc (RUNNING)"
		done
		music_running=true
	fi
	if ! $music_running; then
		echo "  (none detected)"
	fi

	echo ""
	if $focus_running && $music_running; then
		echo "⚠️  CONFLICT: Focus app and music running together!"
		echo "   Music would be killed in monitoring mode."
	elif $focus_running; then
		echo "✓ Focus mode active (no music playing)"
	elif $music_running; then
		echo "✓ Music playing (no focus app detected - this is fine)"
	else
		echo "✓ Idle (nothing detected)"
	fi
}

# Show usage
show_usage() {
	echo "Music Parallelism Prevention Script"
	echo "===================================="
	echo ""
	echo "Usage: $0 [command]"
	echo ""
	echo "Commands:"
	echo "  monitor  - Start monitoring (default, checks every ${CHECK_INTERVAL}s)"
	echo "  instant  - Instant monitoring (${FAST_CHECK_INTERVAL}s active / ${IDLE_CHECK_INTERVAL}s idle)"
	echo "  status   - Show current status of focus apps and music services"
	echo "  kill     - Immediately kill all music services"
	echo "  help     - Show this help message"
	echo ""
	echo "Description:"
	echo "  This script prevents multitasking between focus work and music."
	echo "  When a focus application (VS Code, Steam, etc.) is detected"
	echo "  alongside a music streaming service, the music is stopped."
	echo ""
	echo "  Music is allowed when no focus apps are running."
	echo ""
}
