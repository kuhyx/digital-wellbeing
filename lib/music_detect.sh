#!/bin/bash
# Music-service detection and termination, plus the shared wait helper.
#
# Sourced by music_parallelism.sh; split out to keep it under the 250-line cap.
# Sourced rather than run, so it inherits the caller's strict mode and reads
# the interval, MUSIC_* and PROC_ROOT configuration set above the source line.
#
# find_music_services and kill_music_services stay in one file: the
# MUSIC_FOUND_PROCESS / MUSIC_FOUND_WINDOW pair the first sets and the second
# reads would otherwise cross a file boundary.

wait_seconds() {
	local timeout_s=$1
	local start_ts end_ts elapsed_s remaining_s

	if [[ -n ${MUSIC_PARALLELISM_TEST_WAIT_LOG:-} ]]; then
		printf '%s\n' "$timeout_s" >>"$MUSIC_PARALLELISM_TEST_WAIT_LOG"
		if [[ ${MUSIC_PARALLELISM_TEST_EXIT_AFTER_WAIT:-0} -eq 1 ]]; then
			exit 99
		fi
		return 0
	fi

	printf -v start_ts '%(%s)T' -1
	IFS= read -r -t "$timeout_s" || true
	printf -v end_ts '%(%s)T' -1

	elapsed_s=$((end_ts - start_ts))
	if ((elapsed_s < timeout_s)); then
		remaining_s=$((timeout_s - elapsed_s))
		sleep "$remaining_s"
	fi
}

contains_music_process() {
	local comm_file comm_lower token_lower

	for comm_file in "$PROC_ROOT"/[0-9]*/comm; do
		[[ -r $comm_file ]] || continue
		read -r comm_lower <"$comm_file" || continue
		comm_lower=${comm_lower,,}

		for token_lower in "${MUSIC_PROCESS_NAMES[@]}"; do
			if [[ $comm_lower == *"${token_lower,,}"* ]]; then
				return 0
			fi
		done
	done

	return 1
}

# Check if any music service is running and return its details (OPTIMIZED: batch pgrep calls)
find_music_services() {
	local found_services=()
	MUSIC_FOUND_PROCESS=0
	MUSIC_FOUND_WINDOW=0

	# Check processes using /proc (fork-free)
	if contains_music_process; then
		MUSIC_FOUND_PROCESS=1
		found_services+=("music process")
	fi

	# Check windows (use optimized is_focus_app_running logic: single xdotool regex call)
	if command -v xdotool &>/dev/null && [[ ${#MUSIC_SERVICES[@]} -gt 0 ]]; then
		if xdotool search --name "$MUSIC_WINDOWS_PATTERN" &>/dev/null 2>&1; then
			MUSIC_FOUND_WINDOW=1
			found_services+=("music service (window)")
		fi
	fi

	if [[ ${#found_services[@]} -gt 0 ]]; then
		printf '%s\n' "${found_services[@]}"
		return 0
	fi
	return 1
}

# Kill music services
kill_music_services() {
	local use_cached_detection="${1:-0}"
	local killed=false
	local window_pattern='YouTube Music|music\.youtube\.com|music\.apple\.com|soundcloud\.com|pandora\.com|deezer\.com|tidal\.com'
	local should_check_windows=1
	local should_check_processes=1

	if [[ $use_cached_detection -eq 1 ]]; then
		should_check_windows=$MUSIC_FOUND_WINDOW
		should_check_processes=$MUSIC_FOUND_PROCESS
	fi

	# Close browser tabs for web-based music services via one xdotool search
	if [[ $should_check_windows -eq 1 ]] && command -v xdotool &>/dev/null; then
		local windows wid
		windows=$(xdotool search --name "$window_pattern" 2>/dev/null || true)
		for wid in $windows; do
			[[ -n $wid ]] || continue
			xdotool windowclose "$wid" 2>/dev/null || true
			killed=true
		done
	fi

	# Kill app processes with /proc scan + builtin kill (fork-free in hot path)
	if [[ $should_check_processes -eq 1 ]]; then
		local comm_file pid comm_lower token_lower
		for comm_file in "$PROC_ROOT"/[0-9]*/comm; do
			[[ -r $comm_file ]] || continue
			read -r comm_lower <"$comm_file" || continue
			comm_lower=${comm_lower,,}
			pid=${comm_file#"$PROC_ROOT"/}
			pid=${pid%%/*}

			for token_lower in "${MUSIC_PROCESS_NAMES[@]}"; do
				if [[ $comm_lower == *"${token_lower,,}"* ]]; then
					if [[ $PROC_ROOT != "/proc" ]]; then
						# Test mode (fake proc tree): mark as killed without signaling host PIDs.
						killed=true
					elif kill -9 "$pid" 2>/dev/null; then
						killed=true
					fi
					break
				fi
			done
		done
	fi

	if $killed; then
		return 0
	fi
	return 1
}
