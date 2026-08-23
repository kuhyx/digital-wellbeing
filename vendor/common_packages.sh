#!/bin/bash
# Focus-app detection, command checks and package installation.
#
# Sourced by common.sh, which stays the single entry point every script
# sources -- 49 of them, so the public surface must not change.

# Check if any focus app is running (window-based detection)
# Returns 0 if focus app found, 1 otherwise
# Echoes the name of the found app
# =============================================================================
# FOCUS APP DETECTION (for digital wellbeing scripts)
# =============================================================================

# Default focus apps - can be overridden before calling is_focus_app_running
FOCUS_APPS_WINDOWS=(
	"Visual Studio Code"
	"VSCodium"
	"Cursor"
	"IntelliJ IDEA"
	"PyCharm"
	"WebStorm"
	"CLion"
	"Rider"
	"Sublime Text"
	"Blender"
	"Godot"
	"Unity"
	"Unreal Editor"
)

FOCUS_APPS_PROCESSES=(
	"steam_app_"
	"gamescope"
)


is_focus_app_running() {
	# One xdotool call with a combined regex instead of N separate calls
	if command -v xdotool &>/dev/null && [[ ${#FOCUS_APPS_WINDOWS[@]} -gt 0 ]]; then
		local regex wid
		printf -v regex '%s|' "${FOCUS_APPS_WINDOWS[@]}"
		regex="${regex%|}" # strip trailing |
		while IFS= read -r wid; do
			[[ -n $wid ]] || continue
			echo "focus app"
			return 0
		done < <(xdotool search --name "$regex" 2>/dev/null)
	fi

	# Check specific processes via /proc (no fork)
	local app comm
	for app in "${FOCUS_APPS_PROCESSES[@]}"; do
		for comm in /proc/[0-9]*/comm; do
			[[ -r $comm ]] || continue
			read -r _proc_comm <"$comm" 2>/dev/null || continue
			if [[ $_proc_comm == *"$app"* ]]; then
				echo "$_proc_comm"
				return 0
			fi
		done
	done

	return 1
}

# =============================================================================
# COMMAND AVAILABILITY
# =============================================================================

# Check if a command exists
# Usage: if require_command ffmpeg; then ...
require_command() {
	local cmd="$1"
	local pkg="${2:-$1}"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Error: '$cmd' is not installed or not in PATH." >&2
		echo "Install with: sudo pacman -S $pkg" >&2
		return 1
	fi
	return 0
}

# Check for ImageMagick and display helpful installation message
# Usage: require_imagemagick [optional: "magick" or "convert"]
# Returns: Sets MAGICK_CMD variable to available command
require_imagemagick() {
	local preferred="${1:-}"

	if [[ $preferred == "magick" ]] || [[ -z $preferred ]]; then
		if command -v magick &>/dev/null; then
			MAGICK_CMD="magick"
			export MAGICK_CMD
			return 0
		fi
	fi

	if [[ $preferred == "convert" ]] || [[ -z $preferred ]]; then
		if command -v convert &>/dev/null; then
			MAGICK_CMD="convert"
			export MAGICK_CMD
			return 0
		fi
	fi

	echo "Error: ImageMagick is not installed." >&2
	echo "Install it with:" >&2
	echo "  Arch Linux: sudo pacman -S imagemagick" >&2
	echo "  Ubuntu/Debian: sudo apt install imagemagick" >&2
	return 1
}

# Install missing pacman packages
# Usage: install_missing_pacman_packages pkg1 pkg2 pkg3 ...
# Returns 0 if all packages installed successfully, 1 otherwise
install_missing_pacman_packages() {
	local packages=("$@")
	local missing=()

	for pkg in "${packages[@]}"; do
		if ! pacman -Qi "$pkg" >/dev/null 2>&1; then
			missing+=("$pkg")
		fi
	done

	if [[ ${#missing[@]} -eq 0 ]]; then
		echo "[INFO] All required packages are already installed."
		return 0
	fi

	echo "[INFO] Installing missing packages: ${missing[*]}"
	if ! sudo pacman -S --needed --noconfirm "${missing[@]}"; then
		echo "[ERROR] Failed to install packages" >&2
		return 1
	fi
	return 0
}

# =============================================================================
# NOTIFICATION
# =============================================================================

# Send desktop notification (fails silently if notify-send not available)
# Usage: notify "Title" "Message" [urgency: low/normal/critical] [timeout_ms]
notify() {
	local title="$1"
	local message="$2"
	local urgency="${3:-normal}"
	local timeout="${4:-5000}"

	if command -v notify-send &>/dev/null; then
		notify-send -u "$urgency" -t "$timeout" "$title" "$message" 2>/dev/null || true
	fi
}
