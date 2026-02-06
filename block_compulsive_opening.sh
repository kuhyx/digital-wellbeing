#!/bin/bash
# Block Compulsive Opening Script
# Limits messaging apps (Beeper, Signal, Discord) to one launch per hour
#
# Each app can only be opened once per hour. If already opened this hour,
# subsequent launch attempts are blocked with a notification.
#
# Installation moves real binaries to *.real and symlinks to wrapper scripts.

set -euo pipefail

# Send desktop notification (inlined from common.sh to avoid dependency issues
# when script is installed to /usr/local/bin)
notify() {
	local title="$1"
	local message="$2"
	local urgency="${3:-normal}"
	local timeout="${4:-5000}"

	if command -v notify-send &>/dev/null; then
		notify-send -u "$urgency" -t "$timeout" "$title" "$message" 2>/dev/null || true
	fi
}

# Configuration
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/compulsive-block"
LOG_FILE="$STATE_DIR/compulsive-block.log"

# Auto-close timeout in minutes (apps forcefully closed after this)
AUTO_CLOSE_TIMEOUT_MINUTES=10
# Warning before auto-close (in minutes before timeout)
AUTO_CLOSE_WARNING_MINUTES=2

# Apps to limit (name -> binary path)
# These are the primary wrapper locations (what the user calls)
declare -A APPS=(
	["beeper"]="/usr/bin/beeper"
	["signal-desktop"]="/usr/bin/signal-desktop"
	["discord"]="/usr/bin/discord"
)

# Actual executable paths (the real binaries to exec after wrapper check)
# These are where the real code lives
declare -A REAL_BINARIES=(
	["beeper"]="/opt/beeper/beepertexts"
	["signal-desktop"]="/usr/lib/signal-desktop/signal-desktop"
	["discord"]="/opt/discord/Discord"
)

# Ensure state directory exists
ensure_state_dir() {
	mkdir -p "$STATE_DIR" 2>/dev/null || true
}

# Log message with timestamp
log_message() {
	local msg
	msg="$(date '+%Y-%m-%d %H:%M:%S') - $1"
	echo "$msg" >&2
	echo "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

# Get current hour key (YYYY-MM-DD-HH format)
get_hour_key() {
	date '+%Y-%m-%d-%H'
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
cleanup_stale_running_state() {
	local app="$1"
	local running_file
	running_file=$(get_running_file "$app")

	if [[ ! -f $running_file ]]; then
		return 0
	fi

	local pid
	pid=$(awk '{print $1}' "$running_file" 2>/dev/null || echo "")

	if [[ -z $pid ]]; then
		rm -f "$running_file"
		return 0
	fi

	# Check if process is still running
	if ! kill -0 "$pid" 2>/dev/null; then
		log_message "CLEANUP: Stale running state for $app (PID $pid no longer exists)"
		rm -f "$running_file"
	fi
}

# Launch app with auto-close timer
launch_with_timer() {
	local app="$1"
	local real_binary="$2"
	shift 2

	local warning_seconds=$(((AUTO_CLOSE_TIMEOUT_MINUTES - AUTO_CLOSE_WARNING_MINUTES) * 60))
	local running_file
	running_file=$(get_running_file "$app")

	# Launch the app in background
	"$real_binary" "$@" &
	local app_pid=$!

	# Record state
	echo "$app_pid $(date +%s)" >"$running_file"
	log_message "LAUNCHED: $app with PID $app_pid (auto-close in ${AUTO_CLOSE_TIMEOUT_MINUTES}m)"

	# Spawn the auto-close daemon in a completely detached subshell
	(
		# Detach from terminal
		exec </dev/null >/dev/null 2>&1

		# Wait for warning time
		sleep "$warning_seconds"

		# Check if still running before warning
		if kill -0 "$app_pid" 2>/dev/null; then
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

		# Check if still running
		if kill -0 "$app_pid" 2>/dev/null; then
			# Send final notification
			notify-send -u critical -t 5000 "🚫 $app Session Ended" \
				"Time's up! Closing $app now." 2>/dev/null || true

			# Graceful kill first
			kill "$app_pid" 2>/dev/null || true

			# Wait a moment for graceful shutdown
			sleep 2

			# Force kill if still running
			if kill -0 "$app_pid" 2>/dev/null; then
				kill -9 "$app_pid" 2>/dev/null || true
			fi

			echo "$(date '+%Y-%m-%d %H:%M:%S') - AUTO-CLOSED: $app (PID $app_pid) after ${AUTO_CLOSE_TIMEOUT_MINUTES}m" >>"$LOG_FILE" 2>/dev/null || true
		fi

		rm -f "$running_file" 2>/dev/null || true
	) &
	disown

	# Wait for the app to exit (keeps wrapper process alive while app is running)
	wait "$app_pid" 2>/dev/null || true
	local exit_code=$?

	# Clean up running state
	rm -f "$running_file" 2>/dev/null || true

	log_message "EXITED: $app (PID $app_pid) with code $exit_code"
	return $exit_code
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

# Install wrapper for a specific app
install_wrapper() {
	local app="$1"
	local wrapper_path="${APPS[$app]}"
	local real_binary="${REAL_BINARIES[$app]}"

	# Check if already wrapped
	if [[ -f "${wrapper_path}.orig" ]]; then
		echo "  ✓ $app already wrapped"
		return 0
	fi

	# Check if wrapper location exists (file or symlink)
	if [[ ! -e $wrapper_path && ! -L $wrapper_path ]]; then
		echo "  ⚠ $app not installed ($wrapper_path not found)"
		return 1
	fi

	# Check if real binary exists
	if [[ ! -x $real_binary ]]; then
		echo "  ⚠ $app real binary not found ($real_binary)"
		return 1
	fi

	echo "  Installing wrapper for $app..."

	# Handle symlinks: save the symlink itself, not the target
	if [[ -L $wrapper_path ]]; then
		local link_target
		link_target=$(readlink "$wrapper_path")
		echo "    Saving symlink $wrapper_path -> $link_target as ${wrapper_path}.orig"
		# Remove symlink and create .orig that stores the link target info
		echo "SYMLINK:$link_target" >"${wrapper_path}.orig"
		rm "$wrapper_path"
	else
		echo "    Backing up $wrapper_path -> ${wrapper_path}.orig"
		mv "$wrapper_path" "${wrapper_path}.orig"
	fi

	echo "    Creating wrapper at $wrapper_path"
	cat >"$wrapper_path" <<WRAPPER_EOF
#!/bin/bash
# Auto-generated wrapper for $app - blocks compulsive opening
# Real binary: $real_binary
# Original script: ${wrapper_path}.orig
exec /usr/local/bin/block-compulsive-opening.sh wrapper "$app" "\$@"
WRAPPER_EOF

	chmod +x "$wrapper_path"
	echo "  ✓ $app wrapper installed"
}

# Uninstall wrapper for a specific app
uninstall_wrapper() {
	local app="$1"
	local wrapper_path="${APPS[$app]}"

	if [[ ! -f "${wrapper_path}.orig" ]]; then
		echo "  ⚠ $app wrapper not found"
		return 1
	fi

	echo "  Removing wrapper for $app..."
	rm -f "$wrapper_path"

	# Check if it was a symlink (stored as SYMLINK:target in .orig)
	local orig_content
	orig_content=$(cat "${wrapper_path}.orig" 2>/dev/null || echo "")
	if [[ $orig_content == SYMLINK:* ]]; then
		local link_target="${orig_content#SYMLINK:}"
		echo "    Restoring symlink $wrapper_path -> $link_target"
		ln -s "$link_target" "$wrapper_path"
		rm "${wrapper_path}.orig"
	else
		echo "    Restoring original file"
		mv "${wrapper_path}.orig" "$wrapper_path"
	fi
	echo "  ✓ $app restored"
}

# Install all wrappers
install_all() {
	echo "Installing compulsive opening blockers..."
	echo ""

	# Install main script to /usr/local/bin
	local script_path
	script_path="$(readlink -f "$0")"
	local install_path="/usr/local/bin/block-compulsive-opening.sh"

	if [[ $script_path != "$install_path" ]]; then
		echo "Installing main script to $install_path..."
		cp "$script_path" "$install_path"
		chmod +x "$install_path"
		echo "✓ Main script installed"
	else
		echo "Main script already at $install_path"
	fi
	echo ""

	# Install wrappers for each app
	local installed=0
	for app in "${!APPS[@]}"; do
		if install_wrapper "$app"; then
			((installed++)) || true
		fi
	done

	echo ""
	echo "Installation complete. $installed app(s) wrapped."
	echo ""
	echo "Each app can now only be opened once per hour."
	echo "State files stored in: $STATE_DIR"
	echo "Logs stored in: $LOG_FILE"

	# Install pacman hook to re-wrap after package updates
	install_pacman_hook
}

# Install pacman hook to re-install wrappers after package updates
install_pacman_hook() {
	local hook_dir="/etc/pacman.d/hooks"
	local hook_file="$hook_dir/95-compulsive-block-rewrap.hook"

	echo ""
	echo "Installing pacman hook..."

	mkdir -p "$hook_dir"

	cat >"$hook_file" <<'HOOK_EOF'
[Trigger]
Operation = Upgrade
Operation = Install
Type = Package
Target = beeper
Target = signal-desktop
Target = discord

[Action]
Description = Re-installing compulsive opening blockers after package update
When = PostTransaction
Exec = /usr/local/bin/block-compulsive-opening.sh rewrap-quiet
HOOK_EOF

	chmod 644 "$hook_file"
	echo "✓ Pacman hook installed: $hook_file"
	echo "  Wrappers will be automatically re-installed after beeper/signal/discord updates"
}

# Uninstall pacman hook
uninstall_pacman_hook() {
	local hook_file="/etc/pacman.d/hooks/95-compulsive-block-rewrap.hook"
	if [[ -f $hook_file ]]; then
		rm -f "$hook_file"
		echo "✓ Pacman hook removed"
	fi
}

# Quietly re-wrap apps (for pacman hook - no interactive output)
rewrap_quiet() {
	log_message "REWRAP: Pacman hook triggered, re-installing wrappers"

	for app in "${!APPS[@]}"; do
		local wrapper_path="${APPS[$app]}"

		# Check if wrapper was overwritten (no longer our wrapper script)
		if [[ -f $wrapper_path ]] && ! grep -q "block-compulsive-opening" "$wrapper_path" 2>/dev/null; then
			# Wrapper was overwritten by package update
			log_message "REWRAP: $app wrapper was overwritten, re-installing"

			# Remove old .orig if exists (it's now stale)
			rm -f "${wrapper_path}.orig"

			# Re-install wrapper
			install_wrapper "$app" >>"$LOG_FILE" 2>&1 || true
		fi
	done

	log_message "REWRAP: Complete"
}

# Uninstall all wrappers
uninstall_all() {
	echo "Removing compulsive opening blockers..."
	echo ""

	for app in "${!APPS[@]}"; do
		uninstall_wrapper "$app" || true
	done

	rm -f "/usr/local/bin/block-compulsive-opening.sh"

	# Remove pacman hook
	uninstall_pacman_hook

	echo ""
	echo "Uninstallation complete."
}

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

# Main entry point
main() {
	case "${1:-help}" in
	install)
		if [[ $EUID -ne 0 ]]; then
			echo "Error: install requires root privileges"
			echo "Run: sudo $0 install"
			exit 1
		fi
		install_all
		;;
	uninstall)
		if [[ $EUID -ne 0 ]]; then
			echo "Error: uninstall requires root privileges"
			echo "Run: sudo $0 uninstall"
			exit 1
		fi
		uninstall_all
		;;
	status)
		show_status
		;;
	reset)
		if [[ -z ${2:-} ]]; then
			echo "Error: specify app to reset"
			echo "Apps: ${!APPS[*]}"
			exit 1
		fi
		reset_app "$2"
		;;
	reset-all)
		reset_all
		;;
	rewrap-quiet)
		# Called by pacman hook - quietly re-wrap apps after package updates
		if [[ $EUID -ne 0 ]]; then
			exit 1
		fi
		rewrap_quiet
		;;
	wrapper)
		if [[ -z ${2:-} ]]; then
			echo "Error: wrapper requires app name"
			exit 1
		fi
		wrapper_main "${@:2}"
		;;
	help | -h | --help)
		show_usage
		;;
	*)
		echo "Unknown command: $1"
		show_usage
		exit 1
		;;
	esac
}

main "$@"
