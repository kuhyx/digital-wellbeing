#!/bin/bash
# App-launch path for block_compulsive_opening.sh: the wrapper entry that the
# generated /usr/bin/<app> shims exec into.
# Sourced by the entry script; inherits its strict mode and globals.

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

	if was_opened_this_hour "$app"; then
		block_app "$app"
		exit 1
	fi

	record_opening "$app"

	# The once-per-hour gate is the whole limit: no session timer, so the app
	# replaces this shell and stays open until the user closes it.
	log_message "LAUNCHED: $app"
	exec "$real_binary" "$@"
}
