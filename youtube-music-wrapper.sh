#!/bin/bash
# YouTube Music Wrapper - Blocks launch when focus apps are running
# This replaces the actual youtube-music binary

set -euo pipefail

# Source common library for shared functions
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/../lib/common.sh"

REAL_BINARY="/opt/YouTube Music/youtube-music.real"
LOG_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/music-parallelism/music-parallelism.log"

# Main
if focus_app=$(is_focus_app_running); then
  log_message "BLOCKED: YouTube Music launch prevented (focus app: $focus_app)" "$LOG_FILE"
  notify "🚫 YouTube Music Blocked" "Focus mode active ($focus_app)" normal 3000
  exit 1
fi

# No focus app running, launch normally
exec "$REAL_BINARY" "$@"
