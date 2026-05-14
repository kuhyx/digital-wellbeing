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

wait_seconds() {
  local timeout_s=$1
  local start_ts end_ts elapsed_s remaining_s

  if [[ -n ${MUSIC_PARALLELISM_TEST_WAIT_LOG:-} ]]; then
    printf '%s\n' "$timeout_s" >> "$MUSIC_PARALLELISM_TEST_WAIT_LOG"
    if [[ ${MUSIC_PARALLELISM_TEST_EXIT_AFTER_WAIT:-0} -eq 1 ]]; then
      exit 99
    fi
    return 0
  fi

  printf -v start_ts '%(%s)T' -1
  IFS= read -r -t "$timeout_s" || true
  printf -v end_ts '%(%s)T' -1

  elapsed_s=$((end_ts - start_ts))
  if (( elapsed_s < timeout_s )); then
    remaining_s=$((timeout_s - elapsed_s))
    sleep "$remaining_s"
  fi
}

contains_music_process() {
  local comm_file comm_lower token_lower

  for comm_file in "$PROC_ROOT"/[0-9]*/comm; do
    [[ -r $comm_file ]] || continue
    read -r comm_lower < "$comm_file" || continue
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
  if command -v xdotool &> /dev/null && [[ ${#MUSIC_SERVICES[@]} -gt 0 ]]; then
    if xdotool search --name "$MUSIC_WINDOWS_PATTERN" &> /dev/null 2>&1; then
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
  if [[ $should_check_windows -eq 1 ]] && command -v xdotool &> /dev/null; then
    local windows wid
    windows=$(xdotool search --name "$window_pattern" 2> /dev/null || true)
    for wid in $windows; do
      [[ -n $wid ]] || continue
      xdotool windowclose "$wid" 2> /dev/null || true
      killed=true
    done
  fi

  # Kill app processes with /proc scan + builtin kill (fork-free in hot path)
  if [[ $should_check_processes -eq 1 ]]; then
    local comm_file pid comm_lower token_lower
    for comm_file in "$PROC_ROOT"/[0-9]*/comm; do
      [[ -r $comm_file ]] || continue
      read -r comm_lower < "$comm_file" || continue
      comm_lower=${comm_lower,,}
      pid=${comm_file#"$PROC_ROOT"/}
      pid=${pid%%/*}

      for token_lower in "${MUSIC_PROCESS_NAMES[@]}"; do
        if [[ $comm_lower == *"${token_lower,,}"* ]]; then
          if [[ $PROC_ROOT != "/proc" ]]; then
            # Test mode (fake proc tree): mark as killed without signaling host PIDs.
            killed=true
          elif kill -9 "$pid" 2> /dev/null; then
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
          if kill_music_services 1; then
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

    wait_seconds "$sleep_interval"
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
        if kill_music_services 1; then
          notify_user "$focus_app"
        fi
      fi
    fi

    wait_seconds "$CHECK_INTERVAL"
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

  # Check processes using shared /proc-based helper (fork-free)
  if is_focus_app_running > /dev/null 2>&1; then
    echo "  ✓ Focus process running"
    focus_running=true
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
