#!/bin/bash
# Bachelor Thesis Work Tracker
# Monitors active windows for thesis-related work (Unreal Engine, Unity, Nvidia Omniverse, VS Code with specific repo)
# Unlocks Steam and other distractions only after sufficient work time is accumulated
#
# This daemon runs continuously and:
# 1. Tracks active window time for approved thesis work applications
# 2. Maintains a protected state file with accumulated work time
# 3. Manages hosts file blocking/unblocking based on work quota
# 4. Provides psychological friction against circumvention

set -euo pipefail

# Configuration
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
STATE_DIR="/var/lib/thesis-work-tracker"
STATE_FILE="$STATE_DIR/work-time.state"
LOCK_FILE="$STATE_DIR/tracker.lock"
LOG_DIR="/var/log/thesis-work-tracker"
LOG_FILE="$LOG_DIR/tracker.log"
CHECK_INTERVAL=5  # Check every 5 seconds

# Work requirements (in seconds)
# 2 hours of work = 7200 seconds required before Steam access
WORK_QUOTA_REQUIRED=7200  # 2 hours
WORK_DECAY_PER_HOUR=1800  # Lose 30 minutes per hour of Steam usage

# Thesis work applications - process names and window patterns
# These are the applications that count as "thesis work"
declare -A THESIS_APPS=(
    ["UnrealEditor"]="Unreal Engine"
    ["UE4Editor"]="Unreal Engine 4"
    ["UE5Editor"]="Unreal Engine 5"
    ["Unity"]="Unity Editor"
    ["UnityHub"]="Unity Hub"
    ["Code"]="Visual Studio Code"  # Special handling for repo check
    ["code"]="Visual Studio Code"  # lowercase variant
    ["omniverse"]="Nvidia Omniverse"
    ["kit"]="Nvidia Omniverse Kit"
)

# VS Code specific repo to track
VSCODE_REQUIRED_REPO="praca_magisterska"

# Steam and distraction patterns for hosts blocking
STEAM_DOMAINS=(
    "steampowered.com"
    "steamcommunity.com"
    "steamgames.com"
    "store.steampowered.com"
    "steamcdn-a.akamaihd.net"
    "steamstatic.com"
    "steamusercontent.com"
)

# Additional distraction sites that should be blocked
DISTRACTION_DOMAINS=(
    "reddit.com"
    "twitter.com"
    "x.com"
    "facebook.com"
    "instagram.com"
    "youtube.com"
    "twitch.tv"
    "9gag.com"
    "imgur.com"
)

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Logging function
log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() { log_message "INFO" "$@"; }
log_warn() { log_message "WARN" "$@"; }
log_error() { log_message "ERROR" "$@"; }
log_debug() { 
    if [[ ${DEBUG:-0} -eq 1 ]]; then
        log_message "DEBUG" "$@"
    fi
}

# Initialize directories and state file
init_state() {
    # Create directories with proper permissions
    if [[ ! -d $STATE_DIR ]]; then
        sudo mkdir -p "$STATE_DIR"
        sudo chmod 700 "$STATE_DIR"
    fi
    
    if [[ ! -d $LOG_DIR ]]; then
        sudo mkdir -p "$LOG_DIR"
        sudo chmod 755 "$LOG_DIR"
    fi
    
    # Initialize state file if it doesn't exist
    if [[ ! -f $STATE_FILE ]]; then
        cat <<EOF | sudo tee "$STATE_FILE" > /dev/null
# Thesis Work Tracker State File
# DO NOT EDIT MANUALLY - Managed by thesis_work_tracker daemon
# Last updated: $(date)

TOTAL_WORK_SECONDS=0
LAST_UPDATE_TIMESTAMP=$(date +%s)
STEAM_ACCESS_GRANTED=0
LAST_WORK_SESSION_START=0
CURRENT_SESSION_SECONDS=0
EOF
        sudo chmod 600 "$STATE_FILE"
        if ! sudo chattr +i "$STATE_FILE" 2>/dev/null; then
            log_warn "Failed to set immutable flag on state file - protections may be weaker"
        fi
    fi
}

# Load current state from file
load_state() {
    if [[ ! -f $STATE_FILE ]]; then
        log_error "State file not found: $STATE_FILE"
        return 1
    fi
    
    # Temporarily remove immutable flag to read
    sudo chattr -i "$STATE_FILE" 2>/dev/null || true
    
    # Parse state file safely without using source
    # Only extract the numeric values we need
    TOTAL_WORK_SECONDS=$(grep "^TOTAL_WORK_SECONDS=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    STEAM_ACCESS_GRANTED=$(grep "^STEAM_ACCESS_GRANTED=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    CURRENT_SESSION_SECONDS=$(grep "^CURRENT_SESSION_SECONDS=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    LAST_WORK_SESSION_START=$(grep "^LAST_WORK_SESSION_START=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    LAST_UPDATE_TIMESTAMP=$(grep "^LAST_UPDATE_TIMESTAMP=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    
    # Validate that values are numeric
    if ! [[ $TOTAL_WORK_SECONDS =~ ^[0-9]+$ ]]; then TOTAL_WORK_SECONDS=0; fi
    if ! [[ $STEAM_ACCESS_GRANTED =~ ^[01]$ ]]; then STEAM_ACCESS_GRANTED=0; fi
    if ! [[ $CURRENT_SESSION_SECONDS =~ ^[0-9]+$ ]]; then CURRENT_SESSION_SECONDS=0; fi
    if ! [[ $LAST_WORK_SESSION_START =~ ^[0-9]+$ ]]; then LAST_WORK_SESSION_START=0; fi
    
    # Re-apply immutable flag
    sudo chattr +i "$STATE_FILE" 2>/dev/null || true
}

# Save current state to file
save_state() {
    local total_work="$1"
    local steam_access="$2"
    local current_session="$3"
    local session_start="$4"
    
    # Remove immutable flag
    sudo chattr -i "$STATE_FILE" 2>/dev/null || true
    
    # Write new state
    cat <<EOF | sudo tee "$STATE_FILE" > /dev/null
# Thesis Work Tracker State File
# DO NOT EDIT MANUALLY - Managed by thesis_work_tracker daemon
# Last updated: $(date)

TOTAL_WORK_SECONDS=$total_work
LAST_UPDATE_TIMESTAMP=$(date +%s)
STEAM_ACCESS_GRANTED=$steam_access
LAST_WORK_SESSION_START=$session_start
CURRENT_SESSION_SECONDS=$current_session
EOF
    
    sudo chmod 600 "$STATE_FILE"
    # Re-apply immutable flag
    if ! sudo chattr +i "$STATE_FILE" 2>/dev/null; then
        log_warn "Failed to set immutable flag on state file after save"
    fi
}

# Check if a process is running
is_process_running() {
    local process_name="$1"
    pgrep -x "$process_name" > /dev/null 2>&1
}

# Get active window title and process name
get_active_window_info() {
    if ! command -v xdotool &> /dev/null; then
        log_error "xdotool not installed, cannot detect active window"
        return 1
    fi
    
    local active_window_id
    active_window_id=$(xdotool getactivewindow 2>/dev/null || echo "")
    
    if [[ -z $active_window_id ]]; then
        return 1
    fi
    
    local window_name
    window_name=$(xdotool getwindowname "$active_window_id" 2>/dev/null || echo "")
    
    local window_pid
    window_pid=$(xdotool getwindowpid "$active_window_id" 2>/dev/null || echo "")
    
    local process_name=""
    if [[ -n $window_pid ]]; then
        process_name=$(ps -p "$window_pid" -o comm= 2>/dev/null || echo "")
    fi
    
    echo "${process_name}|${window_name}"
}

# Check if VS Code is working on the required repository
is_vscode_on_thesis_repo() {
    local window_title="$1"
    
    # VS Code window titles typically contain the folder/workspace name
    # Look for the repo name in the window title
    # Window title format is usually: "filename - reponame - Visual Studio Code"
    if [[ $window_title == *"$VSCODE_REQUIRED_REPO"* ]]; then
        return 0
    fi
    
    return 1
}

# Check if current active window is thesis work
is_thesis_work_active() {
    local window_info
    window_info=$(get_active_window_info)
    
    if [[ -z $window_info ]]; then
        return 1
    fi
    
    local process_name
    local window_title
    IFS='|' read -r process_name window_title <<< "$window_info"
    
    log_debug "Active window: process='$process_name' title='$window_title'"
    
    # Check each thesis application
    for proc_pattern in "${!THESIS_APPS[@]}"; do
        local app_name="${THESIS_APPS[$proc_pattern]}"
        
        # Check window title for application name (more reliable than process name)
        if [[ $window_title == *"$app_name"* ]]; then
            # Special handling for VS Code - must be on thesis repo
            if [[ $proc_pattern == "Code" ]] || [[ $proc_pattern == "code" ]]; then
                if is_vscode_on_thesis_repo "$window_title"; then
                    log_debug "Thesis work detected: VS Code on $VSCODE_REQUIRED_REPO"
                    return 0
                else
                    log_debug "VS Code detected but not on thesis repo"
                    continue
                fi
            fi
            
            log_debug "Thesis work detected: $app_name"
            return 0
        fi
        
        # Also check process name with exact match
        if [[ $process_name == "$proc_pattern" ]]; then
            # Special handling for VS Code - must be on thesis repo
            if [[ $proc_pattern == "Code" ]] || [[ $proc_pattern == "code" ]]; then
                if is_vscode_on_thesis_repo "$window_title"; then
                    log_debug "Thesis work detected: VS Code on $VSCODE_REQUIRED_REPO"
                    return 0
                else
                    log_debug "VS Code detected but not on thesis repo"
                    continue
                fi
            fi
            
            log_debug "Thesis work detected: $app_name"
            return 0
        fi
    done
    
    return 1
}

# Block Steam and distractions in /etc/hosts
block_distractions() {
    log_info "Blocking Steam and distractions in /etc/hosts"
    
    # Remove immutable flag temporarily
    sudo chattr -i /etc/hosts 2>/dev/null || true
    
    # Add blocking entries if not already present
    local hosts_modified=0
    
    for domain in "${STEAM_DOMAINS[@]}" "${DISTRACTION_DOMAINS[@]}"; do
        if ! grep -q "^0.0.0.0[[:space:]]*$domain" /etc/hosts 2>/dev/null; then
            echo "0.0.0.0 $domain" | sudo tee -a /etc/hosts > /dev/null
            hosts_modified=1
        fi
    done
    
    # Re-apply immutable flag
    sudo chattr +i /etc/hosts 2>/dev/null || true
    
    if [[ $hosts_modified -eq 1 ]]; then
        log_info "Added distraction blocks to /etc/hosts"
    fi
}

# Unblock Steam and distractions from /etc/hosts
unblock_distractions() {
    log_info "Unblocking Steam and distractions in /etc/hosts"
    
    # Remove immutable flag temporarily
    sudo chattr -i /etc/hosts 2>/dev/null || true
    
    # Remove blocking entries using mktemp for security
    local temp_hosts
    temp_hosts=$(mktemp) || {
        log_error "Failed to create temporary file"
        return 1
    }
    
    sudo cp /etc/hosts "$temp_hosts"
    
    for domain in "${STEAM_DOMAINS[@]}" "${DISTRACTION_DOMAINS[@]}"; do
        sudo sed -i "/^0.0.0.0[[:space:]]*$domain/d" "$temp_hosts"
    done
    
    sudo mv "$temp_hosts" /etc/hosts
    sudo chmod 644 /etc/hosts
    
    # Re-apply immutable flag
    sudo chattr +i /etc/hosts 2>/dev/null || true
    
    log_info "Removed distraction blocks from /etc/hosts"
}

# Check if Steam is currently running (to track decay)
is_steam_running() {
    pgrep -x "steam" > /dev/null 2>&1
}

# Main tracking loop
main_loop() {
    log_info "Starting thesis work tracker daemon"
    
    # Initialize state
    init_state
    
    # Load initial state
    load_state
    
    local total_work_seconds=${TOTAL_WORK_SECONDS:-0}
    local steam_access=${STEAM_ACCESS_GRANTED:-0}
    local session_start=${LAST_WORK_SESSION_START:-0}
    local session_seconds=${CURRENT_SESSION_SECONDS:-0}
    
    # Apply initial blocking state
    if [[ $steam_access -eq 0 ]]; then
        block_distractions
    fi
    
    local last_status_log=$(date +%s)
    local last_decay_check=$(date +%s)
    
    while true; do
        local current_time=$(date +%s)
        
        # Check if thesis work is active
        if is_thesis_work_active; then
            # Track work time
            if [[ $session_start -eq 0 ]]; then
                session_start=$current_time
                log_info "Thesis work session started"
            fi
            
            # Increment session time
            session_seconds=$((session_seconds + CHECK_INTERVAL))
            total_work_seconds=$((total_work_seconds + CHECK_INTERVAL))
            
            # Check if we've reached the quota
            if [[ $total_work_seconds -ge $WORK_QUOTA_REQUIRED ]] && [[ $steam_access -eq 0 ]]; then
                log_info "Work quota reached! Granting Steam access."
                steam_access=1
                unblock_distractions
            fi
            
        else
            # No thesis work active
            if [[ $session_start -ne 0 ]]; then
                log_info "Thesis work session ended. Session duration: $((session_seconds / 60)) minutes"
                session_start=0
                session_seconds=0
            fi
            
            # Check for Steam usage and apply decay
            if [[ $steam_access -eq 1 ]] && is_steam_running; then
                local time_since_decay=$((current_time - last_decay_check))
                if [[ $time_since_decay -ge 3600 ]]; then  # Every hour
                    total_work_seconds=$((total_work_seconds - WORK_DECAY_PER_HOUR))
                    if [[ $total_work_seconds -lt 0 ]]; then
                        total_work_seconds=0
                    fi
                    last_decay_check=$current_time
                    log_info "Steam usage detected. Applied decay. Remaining work time: $((total_work_seconds / 60)) minutes"
                    
                    # Revoke access if below quota
                    if [[ $total_work_seconds -lt $WORK_QUOTA_REQUIRED ]]; then
                        log_info "Work quota depleted. Revoking Steam access."
                        steam_access=0
                        block_distractions
                    fi
                fi
            fi
        fi
        
        # Save state periodically
        save_state "$total_work_seconds" "$steam_access" "$session_seconds" "$session_start"
        
        # Log status every 5 minutes
        if [[ $((current_time - last_status_log)) -ge 300 ]]; then
            local work_minutes=$((total_work_seconds / 60))
            local quota_minutes=$((WORK_QUOTA_REQUIRED / 60))
            local remaining_minutes=$((quota_minutes - work_minutes))
            if [[ $remaining_minutes -lt 0 ]]; then
                remaining_minutes=0
            fi
            
            log_info "Status: Total work time: ${work_minutes}m / ${quota_minutes}m | Steam access: $steam_access | Need: ${remaining_minutes}m more"
            last_status_log=$current_time
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# Handle signals for graceful shutdown
cleanup() {
    log_info "Received shutdown signal, saving state and exiting"
    rm -f "$LOCK_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Check for lock file to prevent multiple instances
if [[ -f $LOCK_FILE ]]; then
    log_error "Another instance is already running (lock file exists: $LOCK_FILE)"
    exit 1
fi

# Create lock file
touch "$LOCK_FILE"

# Run main loop
main_loop
