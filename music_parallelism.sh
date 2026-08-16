#!/bin/bash
# Music Parallelism Prevention Script
# Prevents listening to music while doing focus work (coding, gaming)
#
# When a focus application (VS Code, Steam games, etc.) is detected alongside
# a music streaming service (YouTube Music, Spotify, etc.), the music is stopped.
#
# Music is fine when running alone - only killed when combined with focus apps.

set -euo pipefail

# Source common library for shared functions
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [[ -f "$SCRIPT_DIR/../../lib/common.sh" ]]; then
	# shellcheck source=../../lib/common.sh
	source "$SCRIPT_DIR/../../lib/common.sh"
elif [[ -f "/usr/local/lib/common.sh" ]]; then
	# shellcheck source=/usr/local/lib/common.sh
	# Deployed to /usr/local/lib at install time; no in-repo copy exists at that
	# absolute path for the linter to follow.
	# shellcheck disable=SC1091
	source "/usr/local/lib/common.sh"
else
	echo "ERROR: common.sh library not found"
	exit 1
fi

# Configuration
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/music-parallelism"
mkdir -p "$LOG_DIR" 2>/dev/null || true
export LOG_FILE="$LOG_DIR/music-parallelism.log"
CHECK_INTERVAL=15
FAST_CHECK_INTERVAL=5
IDLE_CHECK_INTERVAL=30
ENFORCEMENT_COOLDOWN=20
PROC_ROOT="${PROC_ROOT:-/proc}"

MUSIC_PROCESS_NAMES=(
	"youtube-music"
	"spotify"
	"tidal"
	"deezer"
	"amazon music"
)

# Override focus apps with extended list for this script
FOCUS_APPS_WINDOWS=(
	# IDEs and code editors - match window titles
	"Visual Studio Code"
	"VSCodium"
	"Cursor"
	"IntelliJ IDEA"
	"PyCharm"
	"WebStorm"
	"CLion"
	"Rider"
	"Sublime Text"
	"Atom"
	"Neovide"
	# Gaming
	"Steam"
	# Creative apps
	"Blender"
	"Godot"
	"Unity"
	"Unreal Editor"
)

# Music streaming services - browser tabs or electron apps
# These will be killed when focus apps are detected
MUSIC_SERVICES=(
	# YouTube Music specific patterns (NOT regular YouTube)
	"music.youtube.com"
	"youtube-music" # Electron app
	"YouTube Music" # Window title
	# Spotify
	"spotify"
	"Spotify"
	# Tidal
	"tidal"
	"TIDAL"
	# Deezer
	"deezer"
	# Amazon Music
	"Amazon Music"
	"amazon music"
	# Apple Music (web)
	"music.apple.com"
	# SoundCloud
	"soundcloud.com"
	# Pandora
	"pandora.com"
)

readonly MUSIC_WINDOWS_PATTERN='YouTube Music|music\.youtube\.com|music\.apple\.com|soundcloud\.com|pandora\.com|deezer\.com|tidal\.com'
readonly ACTIVE_NO_MUSIC_INTERVAL=15
readonly ACTIVE_AFTER_KILL_INTERVAL=5
readonly IDLE_CHECK_INTERVAL=30
MUSIC_FOUND_PROCESS=0
MUSIC_FOUND_WINDOW=0

# Sourced after the configuration above, which they read. music_detect.sh comes
# first: the monitor loops call its helpers.
source "$SCRIPT_DIR/lib/music_detect.sh"
source "$SCRIPT_DIR/lib/music_monitor.sh"
source "$SCRIPT_DIR/lib/music_status.sh"

# Main
case "${1:-instant}" in
monitor | start | run)
	monitor_loop
	;;
instant | fast)
	instant_monitor_loop
	;;
status)
	show_status
	;;
kill)
	log_message "Manual kill requested"
	if kill_music_services; then
		echo "Music services killed"
	else
		echo "No music services found to kill"
	fi
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
