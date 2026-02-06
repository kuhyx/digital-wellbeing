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
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# Configuration
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/music-parallelism"
mkdir -p "$LOG_DIR" 2> /dev/null || true
export LOG_FILE="$LOG_DIR/music-parallelism.log"
CHECK_INTERVAL=3

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

# Check if any music service is running and return its details
find_music_services() {
  local found_services=()

  for service in "${MUSIC_SERVICES[@]}"; do
    # Check for browser tabs with music services
    # This checks window titles which usually contain the URL or tab title
    if command -v xdotool &> /dev/null; then
      if xdotool search --name "$service" &> /dev/null 2>&1; then
        found_services+=("$service (window)")
      fi
    fi

    # Check for dedicated desktop apps
    if pgrep -i -f "$service" &> /dev/null; then
      found_services+=("$service (process)")
    fi
  done

  if [[ ${#found_services[@]} -gt 0 ]]; then
    printf '%s\n' "${found_services[@]}"
    return 0
  fi
  return 1
}

# Kill music services
kill_music_services() {
  local killed=false

  # Kill YouTube Music browser tabs
  # YouTube Music runs in browser, so we need to close specific tabs
  # We use xdotool to find and close windows with "YouTube Music" or "music.youtube.com"
  if command -v xdotool &> /dev/null; then
    # Find windows with YouTube Music in title
    local yt_music_windows
    yt_music_windows=$(xdotool search --name "YouTube Music" 2> /dev/null || true)
    for wid in $yt_music_windows; do
      if [[ -n $wid ]]; then
        # Get window name for logging
        local wname
        wname=$(xdotool getwindowname "$wid" 2> /dev/null || echo "unknown")
        # Only close if it's YouTube Music, not regular YouTube
        if [[ $wname == *"YouTube Music"* ]] || [[ $wname == *"music.youtube.com"* ]]; then
          log_message "Closing YouTube Music window: $wname (ID: $wid)"
          xdotool windowclose "$wid" 2> /dev/null || true
          killed=true
        fi
      fi
    done
  fi

  # Kill YouTube Music Electron app
  if pgrep -f "youtube-music" &> /dev/null; then
    log_message "Killing YouTube Music app"
    pkill -9 -f "youtube-music" 2> /dev/null || true
    killed=true
  fi

  # Kill Spotify
  if pgrep -x "spotify" &> /dev/null; then
    log_message "Killing Spotify"
    pkill -9 -x "spotify" 2> /dev/null || true
    killed=true
  fi

  # Kill other music streaming app processes
  local music_processes=("tidal" "deezer" "Amazon Music")
  for proc in "${music_processes[@]}"; do
    if pgrep -i -f "$proc" &> /dev/null; then
      log_message "Killing $proc"
      pkill -9 -i -f "$proc" 2> /dev/null || true
      killed=true
    fi
  done

  # Close browser tabs for web-based music services
  if command -v xdotool &> /dev/null; then
    local web_music_patterns=("music.apple.com" "soundcloud.com" "pandora.com" "deezer.com" "tidal.com")
    for pattern in "${web_music_patterns[@]}"; do
      local windows
      windows=$(xdotool search --name "$pattern" 2> /dev/null || true)
      for wid in $windows; do
        if [[ -n $wid ]]; then
          local wname
          wname=$(xdotool getwindowname "$wid" 2> /dev/null || echo "unknown")
          log_message "Closing music service window: $wname (ID: $wid)"
          xdotool windowclose "$wid" 2> /dev/null || true
          killed=true
        fi
      done
    done
  fi

  if $killed; then
    return 0
  fi
  return 1
}

# Send notification to user
notify_user() {
  local focus_app="$1"
  local message="Music stopped - focus mode active ($focus_app detected)"

  # Try to send desktop notification
  if command -v notify-send &> /dev/null; then
    notify-send -u normal -t 5000 "🎵 Music Parallelism" "$message" 2> /dev/null || true
  fi

  log_message "$message"
}

# Instant monitoring loop - uses polling at high frequency
# This runs every 0.5 seconds for near-instant detection
instant_monitor_loop() {
  log_message "=== Music Parallelism INSTANT Monitor Started ==="
  log_message "Focus apps (windows): ${FOCUS_APPS_WINDOWS[*]}"
  log_message "Focus apps (processes): ${FOCUS_APPS_PROCESSES[*]}"
  log_message "Polling every 0.5 seconds for instant kill"

  while true; do
    # Only check if focus app is running
    if is_focus_app_running &> /dev/null; then
      # Instant kill youtube-music if detected
      if pgrep -f "youtube-music" &> /dev/null; then
        pkill -9 -f "youtube-music" 2> /dev/null || true
        log_message "INSTANT KILL: YouTube Music terminated"
        notify-send -u normal -t 2000 "🎵 YouTube Music killed" "Focus mode active" 2> /dev/null || true
      fi
      # Also check other music services
      if pgrep -x "spotify" &> /dev/null; then
        pkill -9 -x "spotify" 2> /dev/null || true
        log_message "INSTANT KILL: Spotify terminated"
      fi
    fi
    sleep 0.5
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
      local music_services
      if music_services=$(find_music_services); then
        log_message "Conflict detected: Focus app '$focus_app' running with music services"
        log_message "Active music services: $music_services"

        # Kill the music services
        if kill_music_services; then
          notify_user "$focus_app"
        fi
      fi
    fi

    sleep "$CHECK_INTERVAL"
  done
}

# Show status
show_status() {
  echo "Music Parallelism Monitor Status"
  echo "================================="
  echo ""

  echo "Focus Applications (window-based detection):"
  local focus_running=false

  # Check windows
  if command -v xdotool &> /dev/null; then
    for app in "${FOCUS_APPS_WINDOWS[@]}"; do
      if xdotool search --name "$app" &> /dev/null 2>&1; then
        echo "  ✓ $app (WINDOW OPEN)"
        focus_running=true
      fi
    done
  fi

  # Check processes
  for app in "${FOCUS_APPS_PROCESSES[@]}"; do
    if pgrep -f "$app" &> /dev/null; then
      echo "  ✓ $app (PROCESS RUNNING)"
      focus_running=true
    fi
  done

  if ! $focus_running; then
    echo "  (none detected)"
  fi

  echo ""
  echo "Music Services:"
  local music_running=false
  if music_services=$(find_music_services 2> /dev/null); then
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
  echo "  instant  - Instant monitoring (checks every 0.5s for immediate kill)"
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
