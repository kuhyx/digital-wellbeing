#!/bin/bash
# State and timing helpers for block_compulsive_opening.sh.
# Sourced by the entry script; inherits its strict mode, its notify() helper
# and the STATE_DIR/LOG_FILE/APPS/REAL_BINARIES globals it defines.

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

# Does any installed package own <abs-path>? Reads pacman's local db directly
# instead of `pacman -Qqo`: this runs inside a pacman hook, /usr/bin/pacman is
# kuhy's wrapper, and the hooks are kept file-ops-only. grep's exit codes are
# the answer: 0 owned, 1 unowned, 2 undeterminable (no/unreadable db).
pkg_owns_path() {
	local db="${CCO_PACMAN_LOCAL_DB:-/var/lib/pacman/local}"
	local lists=("$db"/*/files)
	[[ -e ${lists[0]} ]] || return 2
	local rc=0
	grep -qxF -- "${1#/}" "${lists[@]}" 2>/dev/null || rc=$?
	return "$rc"
}

# Remove the leftovers of an app whose package was REMOVED. pacman deletes the
# file on its own path (our wrapper) but never knew about <app>.orig, which is
# the real launcher, so `<app>.orig` would bypass the blocker forever. Only a
# definite "unowned" prunes: an undeterminable db keeps the files, because
# deleting the .orig of a still-installed app breaks launching it.
# Returns 0 when something stale was removed, 1 otherwise. Idempotent.
prune_stale_wrapper() {
	local app="$1"
	local wrapper_path="${APPS[$app]}"
	local orig="${wrapper_path}.orig"
	[[ -e $orig || -L $orig ]] || return 1
	local rc=0
	pkg_owns_path "$wrapper_path" || rc=$?
	((rc == 1)) || return 1
	rm -f "$orig"
	# A wrapper left on the path would exec a .orig that no longer exists.
	if grep -q "block-compulsive-opening" "$wrapper_path" 2>/dev/null; then
		rm -f "$wrapper_path"
	fi
	log_message "PRUNE: $app package removed, deleted stale $orig"
	return 0
}
