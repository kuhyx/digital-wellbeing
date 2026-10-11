#!/bin/bash
# Training Block System - Forces training log entry at system startup
# Blocks all system access until valid training data is recorded
# Uses Plymouth for early boot or YAD for graphical prompts

set -euo pipefail

# ==================== Configuration ====================
TRAINING_LOG_DIR="/var/log/training"
TRAINING_LOG_FILE="${TRAINING_LOG_DIR}/training_log.txt"
LOCK_FILE="/run/training_block.lock"
LOG_FILE="/var/log/training_block.log"

# Automatic timeout for demo mode (in seconds, 0 = disabled)
AUTOMATIC_TIMEOUT=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --automatic_timeout)
      AUTOMATIC_TIMEOUT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ==================== Logging ====================
log_message() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ==================== Environment Setup ====================

# Ensure we have DISPLAY set for GUI
setup_display() {
  # If DISPLAY not set, try to set it
  if [[ -z "${DISPLAY:-}" ]]; then
    # Try to get first active X display
    for display in /tmp/.X11-unix/*; do
      if [[ -S "$display" ]]; then
        local display_num="${display#/tmp/.X11-unix/X}"
        export DISPLAY=":${display_num}"
        log_message "Set DISPLAY to :${display_num}"
        break
      fi
    done
  fi

  # If still no display, we're in early boot - will use text mode
  if [[ -z "${DISPLAY:-}" ]]; then
    log_message "No X display found, will use text mode if needed"
    return 1
  fi

  # Try to find XAUTHORITY
  if [[ -z "${XAUTHORITY:-}" ]]; then
    # Try common locations
    for user_home in /home/*; do
      if [[ -f "${user_home}/.Xauthority" ]]; then
        export XAUTHORITY="${user_home}/.Xauthority"
        log_message "Set XAUTHORITY to ${XAUTHORITY}"
        break
      fi
    done
  fi

  return 0
}

# ==================== Helper Functions ====================

# Get today's date in YYYY-MM-DD format
get_today() {
  date '+%Y-%m-%d'
}

# Check if training log exists for today with valid content
check_training_log_exists() {
  local today
  today=$(get_today)

  if [[ ! -f "$TRAINING_LOG_FILE" ]]; then
    return 1
  fi

  # Check if today's date appears in the log with at least 50 characters of data
  if grep -q "^${today}" "$TRAINING_LOG_FILE"; then
    # Get the line for today and check its length
    local today_entry
    today_entry=$(grep "^${today}" "$TRAINING_LOG_FILE" | tail -n 1)
    local entry_length=${#today_entry}

    if [[ $entry_length -gt 50 ]]; then
      log_message "Found valid training entry for today: ${entry_length} characters"
      return 0
    else
      log_message "Training entry for today is too short (${entry_length} characters), treating as invalid"
      return 1
    fi
  fi

  return 1
}

# Validate running data
validate_running_data() {
  local km="$1"
  local pace="$2"

  # Check if km is a number and reasonable (0.5 to 50)
  if ! [[ "$km" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    return 1
  fi

  if (( $(echo "$km < 0.5" | bc -l) )) || (( $(echo "$km > 50" | bc -l) )); then
    return 1
  fi

  # Check if pace format is valid (MM:SS, reasonable range 3:00 to 10:00 per km)
  if ! [[ "$pace" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
    return 1
  fi

  # Extract minutes and seconds
  local pace_min pace_sec
  pace_min=$(echo "$pace" | cut -d: -f1)
  pace_sec=$(echo "$pace" | cut -d: -f2)

  # Convert to total seconds
  local total_seconds=$((pace_min * 60 + pace_sec))

  # Check reasonable range: 3:00/km (180s) to 10:00/km (600s)
  if (( total_seconds < 180 )) || (( total_seconds > 600 )); then
    return 1
  fi

  return 0
}

# Validate gym data
validate_gym_data() {
  local exercises="$1"
  local sets="$2"
  local reps="$3"
  local weight="$4"

  # Exercises must have at least 3 characters
  if [[ ${#exercises} -lt 3 ]]; then
    return 1
  fi

  # Sets must be 1-10
  if ! [[ "$sets" =~ ^[0-9]+$ ]] || (( sets < 1 )) || (( sets > 10 )); then
    return 1
  fi

  # Reps must be 1-50
  if ! [[ "$reps" =~ ^[0-9]+$ ]] || (( reps < 1 )) || (( reps > 50 )); then
    return 1
  fi

  # Weight must be 0-500 kg (0 for bodyweight)
  if ! [[ "$weight" =~ ^[0-9]+\.?[0-9]*$ ]] || (( $(echo "$weight < 0" | bc -l) )) || (( $(echo "$weight > 500" | bc -l) )); then
    return 1
  fi

  return 0
}

# Show shutdown warning and shutdown
trigger_shutdown() {
  local reason="$1"
  log_message "Triggering shutdown: $reason"

  # Show warning with 5-second countdown
  (
    for i in 5 4 3 2 1; do
      yad --center --on-top --undecorated --skip-taskbar --title="System Shutdown" \
          --text="<b>System will shut down in ${i} seconds</b>\n\n${reason}" \
          --width=500 --height=200 --timeout=1 --no-buttons 2>/dev/null || true
    done
  ) &

  sleep 5
  systemctl poweroff
}

# ==================== GUI Functions ====================

# Show fullscreen blocking splashscreen
show_fullscreen_splash() {
  local title="$1"
  local text="$2"
  local buttons="$3"
  local timeout="${4:-0}"

  # Build timeout parameter
  local timeout_param=()
  if [[ $timeout -gt 0 ]]; then
    timeout_param=("--timeout=$timeout" "--timeout-indicator=bottom")
  fi

  # yad with fullscreen parameters, always on top, undecorated
  # Use multiple flags to ensure it's blocking
  yad --center --on-top --undecorated --skip-taskbar --fixed \
      --title="$title" \
      --text="$text" \
      --width=800 --height=400 \
      --buttons-layout=center \
      --button="$buttons" \
      "${timeout_param[@]}" \
      2>/dev/null

  return $?
}

# Main training prompt
show_training_prompt() {
  log_message "Showing training prompt"

  local timeout_param=()
  if [[ $AUTOMATIC_TIMEOUT -gt 0 ]]; then
    timeout_param=("--timeout=$AUTOMATIC_TIMEOUT" "--timeout-indicator=bottom")
    log_message "Demo mode: will auto-dismiss after ${AUTOMATIC_TIMEOUT} seconds"
  fi

  yad --center --on-top --undecorated --skip-taskbar --fixed \
      --title="Training Check" \
      --text="<big><b>Did you complete your training today?</b></big>\n\nYou must complete training before accessing the system." \
      --width=600 --height=300 \
      --buttons-layout=center \
      --button="Yes:0" \
      --button="No:1" \
      "${timeout_param[@]}" \
      2>/dev/null

  local ret=$?

  # If demo mode and timeout occurred, just exit successfully
  if [[ $AUTOMATIC_TIMEOUT -gt 0 ]] && [[ $ret -eq 70 ]]; then
    log_message "Demo mode: timeout reached, exiting without consequences"
    return 0
  fi

  return $ret
}

# Collect running data
collect_running_data() {
  log_message "Collecting running data"

  while true; do
    local data
    if ! data=$(yad --center --on-top --undecorated --skip-taskbar --fixed \
        --title="Running Details" \
        --text="<b>Enter your running details:</b>" \
        --form \
        --field="Kilometers (0.5-50):" \
        --field="Pace per km (MM:SS, e.g., 5:30):" \
        --width=500 --height=300 \
        --buttons-layout=center \
        --button="Submit:0" \
        2>/dev/null); then
      trigger_shutdown "Training data entry cancelled"
      exit 1
    fi

    # Parse data
    local km pace
    km=$(echo "$data" | cut -d'|' -f1)
    pace=$(echo "$data" | cut -d'|' -f2)

    # Validate
    if validate_running_data "$km" "$pace"; then
      echo "Running: ${km} km at ${pace}/km pace"
      return 0
    else
      yad --center --on-top --undecorated --skip-taskbar \
          --title="Invalid Data" \
          --text="<b>Invalid running data!</b>\n\nKilometers: 0.5-50\nPace: 3:00-10:00 per km\n\nPlease enter realistic values." \
          --width=400 --height=250 \
          --button="Try Again:0" \
          --timeout=3 \
          2>/dev/null || true
    fi
  done
}

# Collect gym data
collect_gym_data() {
  log_message "Collecting gym data"

  while true; do
    local data
    if ! data=$(yad --center --on-top --undecorated --skip-taskbar --fixed \
        --title="Gym Details" \
        --text="<b>Enter your gym workout details:</b>" \
        --form \
        --field="Exercises (e.g., Bench Press, Squats):" \
        --field="Sets (1-10):" \
        --field="Reps (1-50):" \
        --field="Weight in kg (0-500, 0=bodyweight):" \
        --width=500 --height=350 \
        --buttons-layout=center \
        --button="Submit:0" \
        2>/dev/null); then
      trigger_shutdown "Training data entry cancelled"
      exit 1
    fi

    # Parse data
    local exercises sets reps weight
    exercises=$(echo "$data" | cut -d'|' -f1)
    sets=$(echo "$data" | cut -d'|' -f2)
    reps=$(echo "$data" | cut -d'|' -f3)
    weight=$(echo "$data" | cut -d'|' -f4)

    # Validate
    if validate_gym_data "$exercises" "$sets" "$reps" "$weight"; then
      echo "Gym: ${exercises}, ${sets} sets × ${reps} reps @ ${weight} kg"
      return 0
    else
      yad --center --on-top --undecorated --skip-taskbar \
          --title="Invalid Data" \
          --text="<b>Invalid gym data!</b>\n\nExercises: min 3 chars\nSets: 1-10\nReps: 1-50\nWeight: 0-500 kg\n\nPlease enter realistic values." \
          --width=400 --height=300 \
          --button="Try Again:0" \
          --timeout=3 \
          2>/dev/null || true
    fi
  done
}

# Select training type and collect data
collect_training_data() {
  log_message "Prompting for training type"

  yad --center --on-top --undecorated --skip-taskbar --fixed \
      --title="Training Type" \
      --text="<b>What type of training did you do?</b>" \
      --width=500 --height=300 \
      --buttons-layout=center \
      --button="Running:0" \
      --button="Gym:1" \
      2>/dev/null

  local ret=$?

  if [[ $ret -eq 0 ]]; then
    collect_running_data
  elif [[ $ret -eq 1 ]]; then
    collect_gym_data
  else
    trigger_shutdown "Training type selection cancelled"
    exit 1
  fi
}

# Save training data to log
save_training_data() {
  local training_data="$1"
  local today
  today=$(get_today)

  # Ensure directory exists
  mkdir -p "$TRAINING_LOG_DIR"

  # Append to log with timestamp
  echo "${today} | $(date '+%H:%M:%S') | ${training_data}" >> "$TRAINING_LOG_FILE"

  log_message "Training data saved: $training_data"

  # Set proper permissions
  chmod 644 "$TRAINING_LOG_FILE"

  # Show success message
  yad --center --on-top --title="Success" \
      --text="<b>Training logged successfully!</b>\n\nSystem access granted." \
      --width=400 --height=200 \
      --button="OK:0" \
      --timeout=2 \
      2>/dev/null || true
}

# ==================== Main Logic ====================

main() {
  log_message "=== Training Block System Started ==="
  log_message "Automatic timeout: ${AUTOMATIC_TIMEOUT}s (0=disabled)"

  # Ensure log directory exists
  mkdir -p "$TRAINING_LOG_DIR"

  # Check if already processed (lock file exists)
  if [[ -f "$LOCK_FILE" ]]; then
    log_message "Lock file exists, training already checked for this session"
    exit 0
  fi

  # Check if training log exists for today
  if check_training_log_exists; then
    log_message "Training log already exists for today, allowing system access"
    touch "$LOCK_FILE"
    exit 0
  fi

  log_message "No valid training log found for today, blocking system access"

  # Setup display environment for GUI
  if ! setup_display; then
    log_message "WARNING: No display available, cannot show GUI prompts"
    # In early boot without display, we'll wait for display
    log_message "Waiting for display to become available..."
    for i in {1..60}; do
      sleep 1
      if setup_display; then
        log_message "Display available after ${i} seconds"
        break
      fi
    done

    if ! setup_display; then
      log_message "ERROR: Display still not available after 60 seconds"
      # Cannot show GUI, must abort to prevent boot lockup
      trigger_shutdown "Cannot display training prompt - no GUI available"
      exit 1
    fi
  fi

  # If demo mode, just show prompt and exit
  if [[ $AUTOMATIC_TIMEOUT -gt 0 ]]; then
    show_training_prompt
    log_message "Demo mode completed"
    exit 0
  fi

  # Show training prompt
  if ! show_training_prompt; then
    trigger_shutdown "User indicated no training completed"
    exit 1
  fi

  # Collect training data
  local training_data
  training_data=$(collect_training_data)

  # Save training data
  save_training_data "$training_data"

  # Create lock file to prevent re-prompt during same session
  touch "$LOCK_FILE"

  log_message "=== Training Block System Completed Successfully ==="
}

# Run main function
main "$@"
