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
if [[ -f "$SCRIPT_DIR/../lib/common.sh" ]]; then
  # shellcheck source=../lib/common.sh
  source "$SCRIPT_DIR/../lib/common.sh"
elif [[ -f "/usr/local/lib/common.sh" ]]; then
  # shellcheck source=/usr/local/lib/common.sh
  source "/usr/local/lib/common.sh"
else
  echo "ERROR: common.sh library not found"
  exit 1
fi

# Configuration
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/music-parallelism"
mkdir -p "$LOG_DIR" 2> /dev/null || true
export LOG_FILE="$LOG_DIR/music-parallelism.log"
CHECK_INTERVAL=15
FAST_CHECK_INTERVAL=5
IDLE_CHECK_INTERVAL=30
ENFORCEMENT_COOLDOWN=20

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

build_regex_pattern() {
  local -n items=$1
  local pattern

  printf -v pattern '%s|' "${items[@]}"
  printf '%s\n' "${pattern%|}"
}

MUSIC_SERVICES_PATTERN=$(build_regex_pattern MUSIC_SERVICES)
readonly MUSIC_SERVICES_PATTERN
readonly MUSIC_WINDOWS_PATTERN='YouTube Music|music\.youtube\.com|music\.apple\.com|soundcloud\.com|pandora\.com|deezer\.com|tidal\.com'
readonly ACTIVE_NO_MUSIC_INTERVAL=15
readonly ACTIVE_AFTER_KILL_INTERVAL=5
readonly IDLE_CHECK_INTERVAL=30

# Check if any music service is running and return its details (OPTIMIZED: batch pgrep calls)
find_music_services() {
  local found_services=()

  # Check processes (single fork, no per-PID helpers)
  if pgrep -i -f "$MUSIC_SERVICES_PATTERN" &> /dev/null; then
    found_services+=("music process")
  fi

  # Check windows (use optimized is_focus_app_running logic: single xdotool regex call)
  if command -v xdotool &> /dev/null && [[ ${#MUSIC_SERVICES[@]} -gt 0 ]]; then
    if xdotool search --name "$MUSIC_WINDOWS_PATTERN" &> /dev/null 2>&1; then
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
  local killed=false
  local process_pattern='youtube-music|spotify|tidal|deezer|Amazon Music|amazon music'
  local window_pattern='YouTube Music|music\.youtube\.com|music\.apple\.com|soundcloud\.com|pandora\.com|deezer\.com|tidal\.com'

  # Close browser tabs for web-based music services via one xdotool search
  if command -v xdotool &> /dev/null; then
    local windows wid
    windows=$(xdotool search --name "$window_pattern" 2> /dev/null || true)
    for wid in $windows; do
      [[ -n $wid ]] || continue
      xdotool windowclose "$wid" 2> /dev/null || true
      killed=true
    done
  fi

  # Kill app processes with one regex-based pkill
  if pgrep -i -f "$process_pattern" &> /dev/null; then
    pkill -9 -i -f "$process_pattern" 2> /dev/null || true
    killed=true
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
    if focus_app=$(is_focus_app_running 2> /dev/null); then
      current_ts=$(get_timestamp)
      if (( current_ts >= next_enforcement_ts )); then
        if find_music_services > /dev/null 2>&1; then
          if kill_music_services; then
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

    sleep "$sleep_interval"
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

  # Check windows (OPTIMIZED: single xdotool call with combined regex)
  if command -v xdotool &> /dev/null && [[ ${#FOCUS_APPS_WINDOWS[@]} -gt 0 ]]; then
    local regex
    printf -v regex '%s|' "${FOCUS_APPS_WINDOWS[@]}"
    regex="${regex%|}"  # strip trailing |
    if xdotool search --name "$regex" &> /dev/null 2>&1; then
      echo "  ✓ Focus window detected"
      focus_running=true
    fi
  fi

  # Check processes (OPTIMIZED: single pgrep call with combined regex)
  if [[ ${#FOCUS_APPS_PROCESSES[@]} -gt 0 ]]; then
    local proc_pattern
    printf -v proc_pattern '%s|' "${FOCUS_APPS_PROCESSES[@]}"
    proc_pattern="${proc_pattern%|}"  # strip trailing |
    if pgrep -f "$proc_pattern" &> /dev/null; then
      echo "  ✓ Focus process running"
      focus_running=true
    fi
  fi

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
