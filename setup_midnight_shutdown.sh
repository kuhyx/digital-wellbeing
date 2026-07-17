#!/bin/bash
# Script to set up automatic PC shutdown with day-specific time windows
# Monday-Wednesday: Shutdown between 21:00-05:00
# Thursday-Sunday: Shutdown between 22:00-05:00
# Handles sudo privileges automatically

set -e # Exit on any error

# Source common library for shared functions
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"

# Schedule constants (single source of truth for this script)
# These values are written to /etc/shutdown-schedule.conf during setup
SCHEDULE_MON_WED_HOUR=21
SCHEDULE_THU_SUN_HOUR=22
SCHEDULE_MORNING_END_HOUR=5

# ============================================================================
# SCHEDULE PROTECTION MECHANISM
# ============================================================================
# This prevents easy "cheating" by modifying the script values and re-running.
# If a canonical config already exists, the script compares against it and
# BLOCKS installation if the new values would make the schedule MORE LENIENT
# (i.e., later shutdown hours or earlier morning end).
#
# The mechanical protection (chattr, canonical snapshot, path watcher,
# pacman-hook) is provided by guard-lib (guardctl); this ratchet logic and
# the conditional-delay unlock flow below are specific to this one guard
# target and stay bespoke - guardctl's generic `unlock` can't represent
# "hard-block one field, delay only if lenient, no delay if stricter".
# ============================================================================

GUARD_NAME="shutdown-schedule"
CONFIG_FILE="/etc/shutdown-schedule.conf"

# Prints guard-lib's canonical path for our instance, or nothing if the
# instance isn't installed yet (first run on this machine).
canonical_config_path() {
	if command -v guardctl >/dev/null 2>&1 && guardctl file-guard status "$GUARD_NAME" >/dev/null 2>&1; then
		guardctl file-guard canonical-path "$GUARD_NAME"
	fi
}

# Validate that the schedule allows at least MIN_USAGE_HOURS of continuous PC usage.
# The usable window is from SCHEDULE_MORNING_END_HOUR until each shutdown hour.
# Both shutdown hours must independently satisfy the minimum (10 hours).
MIN_USAGE_HOURS=10

validate_minimum_usage_window() {
	local mon_wed_window thu_sun_window
	mon_wed_window=$(( SCHEDULE_MON_WED_HOUR - SCHEDULE_MORNING_END_HOUR ))
	thu_sun_window=$(( SCHEDULE_THU_SUN_HOUR - SCHEDULE_MORNING_END_HOUR ))

	local errors=()

	if [[ $mon_wed_window -le 0 ]]; then
		errors+=("Mon-Wed: morning end (${SCHEDULE_MORNING_END_HOUR}:00) is at or after shutdown (${SCHEDULE_MON_WED_HOUR}:00) — 0 usable hours")
	elif [[ $mon_wed_window -lt $MIN_USAGE_HOURS ]]; then
		errors+=("Mon-Wed: only ${mon_wed_window}h of usable time (${SCHEDULE_MORNING_END_HOUR}:00–${SCHEDULE_MON_WED_HOUR}:00), need at least ${MIN_USAGE_HOURS}h")
	fi

	if [[ $thu_sun_window -le 0 ]]; then
		errors+=("Thu-Sun: morning end (${SCHEDULE_MORNING_END_HOUR}:00) is at or after shutdown (${SCHEDULE_THU_SUN_HOUR}:00) — 0 usable hours")
	elif [[ $thu_sun_window -lt $MIN_USAGE_HOURS ]]; then
		errors+=("Thu-Sun: only ${thu_sun_window}h of usable time (${SCHEDULE_MORNING_END_HOUR}:00–${SCHEDULE_THU_SUN_HOUR}:00), need at least ${MIN_USAGE_HOURS}h")
	fi

	if [[ ${#errors[@]} -gt 0 ]]; then
		echo ""
		echo "╔══════════════════════════════════════════════════════════════════╗"
		echo "║          ❌ INVALID SCHEDULE CONFIGURATION ❌                    ║"
		echo "╚══════════════════════════════════════════════════════════════════╝"
		echo ""
		echo "The schedule constants do not guarantee at least ${MIN_USAGE_HOURS} hours of"
		echo "continuous PC availability. This would cause the PC to shut down"
		echo "immediately or very shortly after it becomes usable."
		echo ""
		for err in "${errors[@]}"; do
			echo "  ✗ $err"
		done
		echo ""
		echo "Fix: ensure (SHUTDOWN_HOUR - MORNING_END_HOUR) >= ${MIN_USAGE_HOURS} for both windows."
		echo "     Example: MORNING_END_HOUR=6, SHUTDOWN_HOUR=22 → 16 usable hours ✓"
		echo ""
		exit 1
	fi
}

# Validate schedule constants immediately (before any sudo escalation or file writes)
validate_minimum_usage_window

# Check if trying to make schedule more lenient (later shutdown / earlier morning end)
check_schedule_protection() {
	local canonical_config
	canonical_config="$(canonical_config_path)"

	# Skip check if no canonical config exists yet (first install)
	if [[ -z $canonical_config ]] || [[ ! -f $canonical_config ]]; then
		return 0
	fi

	# Load canonical values
	local canonical_mon_wed canonical_thu_sun canonical_morning_end
	# shellcheck source=/dev/null
	source "$canonical_config" 2>/dev/null || return 0
	canonical_mon_wed="${MON_WED_HOUR:-}"
	canonical_thu_sun="${THU_SUN_HOUR:-}"
	canonical_morning_end="${MORNING_END_HOUR:-}"

	# If canonical values are empty, skip check
	if [[ -z $canonical_mon_wed ]]; then
		return 0
	fi
	if [[ -z $canonical_thu_sun ]]; then
		return 0
	fi
	if [[ -z $canonical_morning_end ]]; then
		return 0
	fi

	local violations=()

	# Check if Mon-Wed hour is being made LATER (more lenient)
	if [[ $SCHEDULE_MON_WED_HOUR -gt $canonical_mon_wed ]]; then
		violations+=("Mon-Wed shutdown: ${canonical_mon_wed}:00 → ${SCHEDULE_MON_WED_HOUR}:00 (later)")
	fi

	# Check if Thu-Sun hour is being made LATER (more lenient)
	if [[ $SCHEDULE_THU_SUN_HOUR -gt $canonical_thu_sun ]]; then
		violations+=("Thu-Sun shutdown: ${canonical_thu_sun}:00 → ${SCHEDULE_THU_SUN_HOUR}:00 (later)")
	fi

	# Check if morning end is being made EARLIER (more lenient - shorter shutdown window)
	if [[ $SCHEDULE_MORNING_END_HOUR -lt $canonical_morning_end ]]; then
		violations+=("Morning end: 0${canonical_morning_end}:00 → 0${SCHEDULE_MORNING_END_HOUR}:00 (earlier)")
	fi

	if [[ ${#violations[@]} -gt 0 ]]; then
		echo ""
		echo "╔══════════════════════════════════════════════════════════════════╗"
		echo "║               ❌ OPERATION NOT PERMITTED ❌                      ║"
		echo "╚══════════════════════════════════════════════════════════════════╝"
		echo ""
		echo "The requested schedule modification has been denied."
		echo ""
		exit 1
	fi

	# Making schedule STRICTER is always allowed
	local stricter=()
	if [[ $SCHEDULE_MON_WED_HOUR -lt $canonical_mon_wed ]]; then
		stricter+=("Mon-Wed: ${canonical_mon_wed}:00 → ${SCHEDULE_MON_WED_HOUR}:00 (earlier)")
	fi
	if [[ $SCHEDULE_THU_SUN_HOUR -lt $canonical_thu_sun ]]; then
		stricter+=("Thu-Sun: ${canonical_thu_sun}:00 → ${SCHEDULE_THU_SUN_HOUR}:00 (earlier)")
	fi
	if [[ $SCHEDULE_MORNING_END_HOUR -gt $canonical_morning_end ]]; then
		stricter+=("Morning end: 0${canonical_morning_end}:00 → 0${SCHEDULE_MORNING_END_HOUR}:00 (later)")
	fi

	if [[ ${#stricter[@]} -gt 0 ]]; then
		echo ""
		echo "ℹ️  Schedule is being made STRICTER (allowed without unlock):"
		for s in "${stricter[@]}"; do
			echo "  • $s"
		done
		echo ""
	fi

	return 0
}

# Function to show usage
show_usage() {
	echo "Day-Specific Auto-Shutdown Setup for Arch Linux"
	echo "==============================================="
	echo "Usage: $0 [enable|status]"
	echo ""
	echo "Commands:"
	echo "  enable   - Set up automatic shutdown with day-specific windows (default)"
	echo "  status   - Show current status"
	echo ""
	echo "Shutdown Schedule:"
	echo "  Monday-Wednesday: ${SCHEDULE_MON_WED_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00"
	echo "  Thursday-Sunday:  ${SCHEDULE_THU_SUN_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00"
	echo ""
	echo "NOTE: There is no 'disable' option. This is intentional."
	echo "      The shutdown timer is protected by a monitor service."
	echo ""
}

# Function to check and request sudo privileges
check_sudo() {
	if [[ $EUID -ne 0 ]]; then
		echo "This script requires sudo privileges to manage systemd services."
		echo "Requesting sudo access..."
		exec sudo "$0" "$@"
	fi
}

# Get the actual user (even when running with sudo)
set_actual_user_vars

# Function to show current status
show_current_status() {
	echo "Day-Specific Auto-Shutdown Status"
	echo "================================="
	echo "Current Date: $(date)"
	echo "User: $ACTUAL_USER"
	echo ""

	local timer_exists=false

	# Check if files exist
	if [[ -f "/etc/systemd/system/day-specific-shutdown.timer" ]]; then
		timer_exists=true
		echo "✓ Timer file exists"
	else
		echo "✗ Timer file missing"
	fi

	if [[ -f "/etc/systemd/system/day-specific-shutdown.service" ]]; then
		echo "✓ Service file exists"
	else
		echo "✗ Service file missing"
	fi

	if [[ -f "/usr/local/bin/day-specific-shutdown-manager.sh" ]]; then
		echo "✓ Management script exists"
	else
		echo "✗ Management script missing"
	fi

	if [[ -f "/usr/local/bin/shutdown-timer-monitor.sh" ]]; then
		echo "✓ Monitor script exists"
	else
		echo "✗ Monitor script missing"
	fi

	echo ""

	# Check systemd status
	if $timer_exists; then
		if systemctl is-enabled day-specific-shutdown.timer &>/dev/null; then
			echo "✓ Timer is enabled"
			if systemctl is-active day-specific-shutdown.timer &>/dev/null; then
				echo "✓ Timer is active"
				echo ""
				echo "Next scheduled shutdown check:"
				systemctl list-timers day-specific-shutdown.timer --no-pager 2>/dev/null | grep day-specific-shutdown || echo "Timer information not available"
			else
				echo "✗ Timer is not active"
			fi
		else
			echo "✗ Timer is not enabled"
		fi
	else
		echo "Status: NOT CONFIGURED"
	fi

	echo ""

	# Check monitor service status
	echo "Monitor Service Status:"
	if systemctl is-enabled shutdown-timer-monitor.service &>/dev/null; then
		echo "✓ Monitor is enabled"
		if systemctl is-active shutdown-timer-monitor.service &>/dev/null; then
			echo "✓ Monitor is active (will re-enable timer if disabled)"
		else
			echo "✗ Monitor is not active"
		fi
	else
		echo "✗ Monitor is not enabled"
	fi

	echo ""

	# Check config file protection status (via guard-lib)
	echo "Config File Protection Status:"
	local canonical_file
	canonical_file="$(canonical_config_path)"

	if [[ -f $CONFIG_FILE ]]; then
		echo "✓ Config file exists"
		# Check immutable attribute
		if lsattr "$CONFIG_FILE" 2>/dev/null | grep -q '^....i'; then
			echo "✓ Config file is immutable (chattr +i)"
		else
			echo "✗ Config file is NOT immutable"
		fi
	else
		echo "✗ Config file missing"
	fi

	if [[ -n $canonical_file ]] && [[ -f $canonical_file ]]; then
		echo "✓ Canonical copy exists ($canonical_file)"
	else
		echo "✗ Canonical copy missing (guard-lib instance not installed?)"
	fi

	if systemctl is-enabled "guard-file@${GUARD_NAME}.path" &>/dev/null; then
		echo "✓ Config path watcher is enabled"
		if systemctl is-active "guard-file@${GUARD_NAME}.path" &>/dev/null; then
			echo "✓ Config path watcher is active"
		else
			echo "✗ Config path watcher is not active"
		fi
	else
		echo "✗ Config path watcher is not enabled"
	fi

	echo ""
	echo "Shutdown Schedule:"
	echo "  Monday-Wednesday: ${SCHEDULE_MON_WED_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00"
	echo "  Thursday-Sunday:  ${SCHEDULE_THU_SUN_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00"
	echo ""
	echo "NOTE: The shutdown timer is protected by a monitor service."
	echo "      If you try to disable the timer, it will be automatically re-enabled."
	echo ""
	echo "NOTE: The config file is protected by:"
	echo "      - Immutable attribute (chattr +i)"
	echo "      - Canonical copy that auto-restores on modification"
	echo "      - Path watcher service"
	echo ""

	echo "Active Overrides:"
	if command -v /usr/local/bin/shutdown-override-manager.sh >/dev/null 2>&1; then
		/usr/local/bin/shutdown-override-manager.sh list | sed 's/^/  /'
	else
		echo "  (override manager not installed)"
	fi
	echo ""
}

# Function to create/update shutdown schedule config file (shared with
# i3blocks countdown). Mechanical protection (canonical snapshot, chattr,
# path watcher) is guard-lib's job via create_config_guard() below; this
# function only decides what content should exist.
create_shutdown_config() {
	echo ""
	echo "1. Creating Shutdown Schedule Config..."
	echo "======================================="

	local new_content
	new_content="$(cat <<EOF
# Shutdown schedule configuration
# This file is managed by setup_midnight_shutdown.sh
# Used by: day-specific-shutdown-check.sh, shutdown_countdown.sh (i3blocks)
#
# WARNING: This file is protected by guard-lib (guardctl): immutable
# attribute, a canonical copy, and a path watcher that auto-restores it
# if modified outside the sanctioned unlock flow.

# Shutdown hour for Monday-Wednesday (24-hour format)
MON_WED_HOUR=${SCHEDULE_MON_WED_HOUR}

# Shutdown hour for Thursday-Sunday (24-hour format)
THU_SUN_HOUR=${SCHEDULE_THU_SUN_HOUR}

# Morning end hour (shutdown window ends at this hour)
MORNING_END_HOUR=${SCHEDULE_MORNING_END_HOUR}
EOF
)"

	if guardctl file-guard status "$GUARD_NAME" >/dev/null 2>&1; then
		# Already installed and this content already passed
		# check_schedule_protection's ratchet check above - apply it
		# directly, canonical first then target (same race-avoidance
		# order adjust_shutdown_schedule.sh uses), then re-lock both.
		local canonical_file
		canonical_file="$(guardctl file-guard canonical-path "$GUARD_NAME")"
		chattr -i "$canonical_file" 2>/dev/null || true
		chattr -i "$CONFIG_FILE" 2>/dev/null || true
		echo "$new_content" >"$canonical_file"
		chmod 644 "$canonical_file"
		chattr +i "$canonical_file" || echo "⚠ Warning: Could not set immutable attribute on $canonical_file"
		echo "$new_content" >"$CONFIG_FILE"
		chmod 644 "$CONFIG_FILE"
		chattr +i "$CONFIG_FILE" || echo "⚠ Warning: Could not set immutable attribute on $CONFIG_FILE"
		echo "✓ Updated config and canonical copy: $CONFIG_FILE"
	else
		# First install: guard-lib's install snapshots this content as
		# the canonical copy, so just write the plain file here.
		echo "$new_content" >"$CONFIG_FILE"
		chmod 644 "$CONFIG_FILE"
		echo "✓ Created shutdown schedule config: $CONFIG_FILE"
	fi
}

# Function to install guard-lib protection (path watcher + enforcement)
# and the bespoke ratchet-aware unlock script.
create_config_guard() {
	echo ""
	echo "2. Installing Config Guard (guard-lib + unlock script)..."
	echo "=========================================================="

	command -v guardctl >/dev/null 2>&1 || {
		echo "Error: guardctl not found on PATH. Set up ~/guard-lib first (run its install.sh)." >&2
		exit 1
	}

	if guardctl file-guard status "$GUARD_NAME" >/dev/null 2>&1; then
		echo "✓ guard-lib instance '$GUARD_NAME' already installed (content applied above)"
	else
		guardctl file-guard install "$GUARD_NAME" --target "$CONFIG_FILE"
		echo "✓ Installed guard-lib file-guard '$GUARD_NAME' (canonical snapshot, chattr +i, path watcher, initial enforcement)"
	fi

	# Obscure name for unlock script - not documented anywhere
	local unlock_script="/usr/local/sbin/.sd-sched-mgmt"

	# Create unlock script with psychological delay
	cat >"$unlock_script" <<'EOF'
#!/bin/bash
# Unlock shutdown schedule config for editing with smart friction
# This script:
#   - NO delay if making schedule STRICTER (earlier shutdown hours)
#   - DELAY if making schedule more LENIENT (later shutdown hours)
#   - BLOCKS lowering MORNING_END_HOUR (that would shorten the shutdown window)

set -euo pipefail

DELAY_SECONDS=45
GUARD_NAME="shutdown-schedule"
CONFIG_FILE="/etc/shutdown-schedule.conf"
LOG_FILE="/var/log/shutdown-schedule-guard.log"
EDITOR="${EDITOR:-nano}"
TEMP_FILE="/tmp/shutdown-schedule-edit.$$"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

CANONICAL_FILE="$(guardctl file-guard canonical-path "$GUARD_NAME")"
if [[ -z "$CANONICAL_FILE" ]]; then
    echo "Error: guard-lib instance '$GUARD_NAME' is not installed (guardctl file-guard canonical-path returned empty)" >&2
    exit 1
fi

# Log the unlock attempt
log "=== UNLOCK ATTEMPT by $(logname 2>/dev/null || echo 'unknown') from TTY $(tty 2>/dev/null || echo 'unknown') ==="

# Load current values
OLD_MON_WED=""
OLD_THU_SUN=""
OLD_MORNING_END=""
if [[ -f "$CANONICAL_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CANONICAL_FILE" 2>/dev/null || true
    OLD_MON_WED="${MON_WED_HOUR:-}"
    OLD_THU_SUN="${THU_SUN_HOUR:-}"
    OLD_MORNING_END="${MORNING_END_HOUR:-}"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║          SHUTDOWN SCHEDULE CONFIG UNLOCK                        ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Current schedule:"
echo "  Monday-Wednesday: ${OLD_MON_WED:-??}:00 - 0${OLD_MORNING_END:-?}:00"
echo "  Thursday-Sunday:  ${OLD_THU_SUN:-??}:00 - 0${OLD_MORNING_END:-?}:00"
echo ""
echo "Rules:"
echo "  ✓ Making shutdown EARLIER (stricter) = No delay"
echo "  ⏳ Making shutdown LATER (lenient) = ${DELAY_SECONDS}s delay required"
echo "  ❌ Lowering MORNING_END_HOUR = BLOCKED (would shorten shutdown window)"
echo ""

# Stop the path watcher temporarily. This is NOT optional: `chattr -i`
# below is itself enough to fire guard-file@shutdown-schedule.path (its
# PathModified reacts to attribute changes, not just content writes), and
# that watcher's enforce pass unconditionally re-locks the target at the
# end even when no drift is found - which would silently re-lock the file
# out from under us during the 45s delay below. Confirmed live: without
# this stop, the delayed-apply cp failed with "Operation not permitted".
systemctl stop "guard-file@${GUARD_NAME}.path" 2>/dev/null || true

# Remove immutable attributes
chattr -i -a "$CONFIG_FILE" 2>/dev/null || true
chattr -i -a "$CANONICAL_FILE" 2>/dev/null || true

# Copy config to temp file for editing
cp "$CONFIG_FILE" "$TEMP_FILE"

echo "Opening editor..."
echo ""

# Open editor on temp file
$EDITOR "$TEMP_FILE"

# Load new values from edited file
NEW_MON_WED=""
NEW_THU_SUN=""
NEW_MORNING_END=""
# shellcheck source=/dev/null
source "$TEMP_FILE" 2>/dev/null || true
NEW_MON_WED="${MON_WED_HOUR:-}"
NEW_THU_SUN="${THU_SUN_HOUR:-}"
NEW_MORNING_END="${MORNING_END_HOUR:-}"

echo ""
echo "Checking changes..."

# Check for blocked changes (lowering MORNING_END_HOUR)
if [[ -n "$OLD_MORNING_END" ]] && [[ -n "$NEW_MORNING_END" ]]; then
    if [[ "$NEW_MORNING_END" -lt "$OLD_MORNING_END" ]]; then
        echo ""
        echo "╔══════════════════════════════════════════════════════════════════╗"
        echo "║     ❌ CHANGE BLOCKED - CANNOT LOWER MORNING_END_HOUR ❌        ║"
        echo "╚══════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "You tried to lower MORNING_END_HOUR from $OLD_MORNING_END to $NEW_MORNING_END"
        echo "This would SHORTEN the shutdown window, making it more lenient."
        echo ""
        echo "This change is NOT allowed. The shutdown window must end at"
        echo "0${OLD_MORNING_END}:00 or later."
        echo ""
        rm -f "$TEMP_FILE"
        # Re-apply protection
        chattr +i "$CONFIG_FILE" 2>/dev/null || true
        chattr +i "$CANONICAL_FILE" 2>/dev/null || true
        systemctl start "guard-file@${GUARD_NAME}.path" 2>/dev/null || true
        log "BLOCKED: User tried to lower MORNING_END_HOUR from $OLD_MORNING_END to $NEW_MORNING_END"
        exit 1
    fi
fi

# Check if changes require delay (making schedule more lenient)
NEEDS_DELAY=false
LENIENT_CHANGES=()

if [[ -n "$OLD_MON_WED" ]] && [[ -n "$NEW_MON_WED" ]]; then
    if [[ "$NEW_MON_WED" -gt "$OLD_MON_WED" ]]; then
        NEEDS_DELAY=true
        LENIENT_CHANGES+=("Mon-Wed: ${OLD_MON_WED}:00 → ${NEW_MON_WED}:00 (later)")
    fi
fi

if [[ -n "$OLD_THU_SUN" ]] && [[ -n "$NEW_THU_SUN" ]]; then
    if [[ "$NEW_THU_SUN" -gt "$OLD_THU_SUN" ]]; then
        NEEDS_DELAY=true
        LENIENT_CHANGES+=("Thu-Sun: ${OLD_THU_SUN}:00 → ${NEW_THU_SUN}:00 (later)")
    fi
fi

# Check for stricter changes (allowed without delay)
STRICTER_CHANGES=()

if [[ -n "$OLD_MON_WED" ]] && [[ -n "$NEW_MON_WED" ]]; then
    if [[ "$NEW_MON_WED" -lt "$OLD_MON_WED" ]]; then
        STRICTER_CHANGES+=("Mon-Wed: ${OLD_MON_WED}:00 → ${NEW_MON_WED}:00 (earlier)")
    fi
fi

if [[ -n "$OLD_THU_SUN" ]] && [[ -n "$NEW_THU_SUN" ]]; then
    if [[ "$NEW_THU_SUN" -lt "$OLD_THU_SUN" ]]; then
        STRICTER_CHANGES+=("Thu-Sun: ${OLD_THU_SUN}:00 → ${NEW_THU_SUN}:00 (earlier)")
    fi
fi

if [[ -n "$OLD_MORNING_END" ]] && [[ -n "$NEW_MORNING_END" ]]; then
    if [[ "$NEW_MORNING_END" -gt "$OLD_MORNING_END" ]]; then
        STRICTER_CHANGES+=("Morning end: 0${OLD_MORNING_END}:00 → 0${NEW_MORNING_END}:00 (later = longer window)")
    fi
fi

# Report stricter changes
if [[ ${#STRICTER_CHANGES[@]} -gt 0 ]]; then
    echo ""
    echo "✓ Stricter changes detected (no delay needed):"
    for s in "${STRICTER_CHANGES[@]}"; do
        echo "  • $s"
    done
fi

# Handle lenient changes
if [[ "$NEEDS_DELAY" == true ]]; then
    echo ""
    echo "⚠️  More lenient changes detected:"
    for l in "${LENIENT_CHANGES[@]}"; do
        echo "  • $l"
    done
    echo ""
    echo "Are you making this change for a good reason, or are you just"
    echo "trying to stay up later? Remember why you set these limits."
    echo ""
    echo "To proceed, you must wait $DELAY_SECONDS seconds..."
    echo ""

    # Countdown with opportunity to cancel
    for ((i=DELAY_SECONDS; i>0; i--)); do
        printf "\r  ⏳ Waiting: %2d seconds remaining... (Ctrl+C to cancel)" "$i"
        sleep 1
    done
    echo ""
    echo ""
    log "User waited through delay for lenient changes: ${LENIENT_CHANGES[*]}"
else
    echo ""
    echo "✓ No delay required (schedule is same or stricter)"
fi

# Apply the changes
cp "$TEMP_FILE" "$CONFIG_FILE"
cp "$TEMP_FILE" "$CANONICAL_FILE"
rm -f "$TEMP_FILE"

chmod 644 "$CONFIG_FILE"
chmod 644 "$CANONICAL_FILE"

# Re-apply immutable
chattr +i "$CONFIG_FILE" || echo "Warning: Could not set immutable attribute"
chattr +i "$CANONICAL_FILE" || echo "Warning: Could not set immutable attribute"

# Restart path watcher (stopped near the start of this script)
systemctl start "guard-file@${GUARD_NAME}.path" 2>/dev/null || true

log "Config updated and re-locked by user"

echo ""
echo "✓ Config file updated and re-protected"
echo "✓ Canonical copy updated"
echo "✓ Path watcher re-enabled"
echo ""
echo "New schedule (will take effect on next timer check):"
# shellcheck source=/dev/null
source "$CONFIG_FILE" 2>/dev/null || true
echo "  Monday-Wednesday: ${MON_WED_HOUR:-??}:00 - 0${MORNING_END_HOUR:-?}:00"
echo "  Thursday-Sunday:  ${THU_SUN_HOUR:-??}:00 - 0${MORNING_END_HOUR:-?}:00"
echo ""
EOF

	chmod +x "$unlock_script"
	# Silently create unlock script - do not announce its existence
}

# Function to create the shutdown service
create_shutdown_service() {
	echo ""
	echo "3. Creating Systemd Shutdown Service..."
	echo "======================================"

	local service_file="/etc/systemd/system/day-specific-shutdown.service"

	cat >"$service_file" <<'EOF'
[Unit]
Description=Automatic PC shutdown with day-specific time windows
DefaultDependencies=false
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/day-specific-shutdown-check.sh
TimeoutStartSec=0
StandardOutput=journal
StandardError=journal
EOF

	echo "✓ Created systemd service: $service_file"
}

# Function to create the shutdown timer
create_shutdown_timer() {
	echo ""
	echo "4. Creating Systemd Shutdown Timer..."
	echo "==================================="

	local timer_file="/etc/systemd/system/day-specific-shutdown.timer"

	# Calculate earliest shutdown hour (minimum of MON_WED and THU_SUN)
	local earliest_hour=$SCHEDULE_MON_WED_HOUR
	if [[ $SCHEDULE_THU_SUN_HOUR -lt $earliest_hour ]]; then
		earliest_hour=$SCHEDULE_THU_SUN_HOUR
	fi

	# Generate timer entries dynamically from earliest_hour to MORNING_END_HOUR
	# This ensures timer fires at all possible shutdown times
	{
		cat <<EOF
[Unit]
Description=Timer for automatic PC shutdown with day-specific windows
Requires=day-specific-shutdown.service

[Timer]
EOF
		# Evening hours: from earliest shutdown hour to 23:30
		for hour in $(seq "$earliest_hour" 23); do
			printf 'OnCalendar=*-*-* %02d:00:00\n' "$hour"
			printf 'OnCalendar=*-*-* %02d:30:00\n' "$hour"
		done

		# Morning hours: from 00:00 to MORNING_END_HOUR
		for hour in $(seq 0 "$SCHEDULE_MORNING_END_HOUR"); do
			printf 'OnCalendar=*-*-* %02d:00:00\n' "$hour"
			if [[ $hour -lt $SCHEDULE_MORNING_END_HOUR ]]; then
				printf 'OnCalendar=*-*-* %02d:30:00\n' "$hour"
			fi
		done

		cat <<EOF
Persistent=false
AccuracySec=1s
WakeSystem=false
RandomizedDelaySec=0

[Install]
WantedBy=timers.target
EOF
	} >"$timer_file"

	echo "✓ Created systemd timer: $timer_file"
	echo "  Timer covers: ${earliest_hour}:00 to 0${SCHEDULE_MORNING_END_HOUR}:00"
}

# Function to create management script
create_management_script() {
	echo ""
	echo "5. Creating Management Script..."
	echo "=============================="

	local script_file="/usr/local/bin/day-specific-shutdown-manager.sh"

	cat >"$script_file" <<'EOF'
#!/bin/bash
# Day-Specific Auto-Shutdown Manager
# Provides easy management of the day-specific shutdown feature

TIMER_NAME="day-specific-shutdown.timer"
SERVICE_NAME="day-specific-shutdown.service"
CONFIG_FILE="/etc/shutdown-schedule.conf"

# Load config for schedule display
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        echo "Warning: Config file $CONFIG_FILE not found"
        MON_WED_HOUR="??"
        THU_SUN_HOUR="??"
        MORNING_END_HOUR="??"
    fi
}

print_schedule() {
    load_config
    echo "Shutdown Schedule:"
    echo "  Monday-Wednesday: ${MON_WED_HOUR}:00-0${MORNING_END_HOUR}:00"
    echo "  Thursday-Sunday:  ${THU_SUN_HOUR}:00-0${MORNING_END_HOUR}:00"
}

show_status() {
    echo "Day-Specific Auto-Shutdown Status"
    echo "================================="

    if systemctl is-enabled "$TIMER_NAME" &>/dev/null; then
        echo "Status: ENABLED"
        if systemctl is-active "$TIMER_NAME" &>/dev/null; then
            echo "Timer: ACTIVE"
        else
            echo "Timer: INACTIVE"
        fi
    else
        echo "Status: NOT ENABLED"
    fi

    echo ""
    print_schedule

    echo ""
    echo "Next scheduled checks:"
    systemctl list-timers "$TIMER_NAME" --no-pager 2>/dev/null | grep "$TIMER_NAME" || echo "Timer not active"

    echo ""
    echo "Recent logs:"
    journalctl -u "$SERVICE_NAME" --no-pager -n 5 2>/dev/null || echo "No recent logs"
}

case "$1" in
    "status")
        show_status
        ;;
    "logs")
        echo "Day-Specific Auto-Shutdown Logs"
        echo "==============================="
        journalctl -u "$SERVICE_NAME" --no-pager -n 20
        ;;
    *)
        echo "Day-Specific Auto-Shutdown Manager"
        echo "Usage: $0 {status|logs}"
        echo ""
        echo "Commands:"
        echo "  status   - Show current status and next shutdown checks"
        echo "  logs     - Show recent shutdown logs"
        echo ""
        print_schedule
        echo ""
        show_status
        ;;
esac
EOF

	chmod +x "$script_file"
	echo "✓ Created management script: $script_file"
}

# Function to create smart shutdown check script
create_shutdown_check_script() {
	echo ""
	echo "6. Creating Smart Shutdown Check Script..."
	echo "========================================"

	local check_script="/usr/local/bin/day-specific-shutdown-check.sh"

	cat >"$check_script" <<'EOF'
#!/bin/bash
# Smart day-specific shutdown check script
# Reads shutdown windows from /etc/shutdown-schedule.conf

CONFIG_FILE="/etc/shutdown-schedule.conf"
OVERRIDES_FILE="/etc/shutdown-schedule-overrides.conf"

# Time-boxed exceptions (e.g. watching a live event that runs past the normal
# shutdown window) are registered via shutdown-override-manager.sh, which
# appends "start_epoch|end_epoch|created_epoch|reason" lines to OVERRIDES_FILE.
# Entries are absolute-epoch-bound so they expire on their own; this function
# prunes stale lines and returns success (skip shutdown) if now falls inside
# any remaining window.
check_active_override() {
    [[ -f "$OVERRIDES_FILE" ]] || return 1

    local now
    now=$(printf '%(%s)T' -1)

    local kept=""
    local active=false
    local active_reason=""
    local start_epoch end_epoch _created reason

    while IFS='|' read -r start_epoch end_epoch _created reason; do
        [[ -n "$start_epoch" ]] || continue
        if [[ $end_epoch -lt $now ]]; then
            continue # expired, drop it
        fi
        kept+="${start_epoch}|${end_epoch}|${_created}|${reason}"$'\n'
        if [[ $now -ge $start_epoch ]] && [[ $now -le $end_epoch ]]; then
            active=true
            active_reason="$reason"
        fi
    done <"$OVERRIDES_FILE"

    printf '%s' "$kept" >"$OVERRIDES_FILE"

    if [[ $active == true ]]; then
        logger -t day-specific-shutdown "Active override in effect (reason: ${active_reason}) - skipping shutdown check"
        return 0
    fi
    return 1
}

if check_active_override; then
    exit 0
fi

# Load config
if [[ ! -f "$CONFIG_FILE" ]]; then
    logger -t day-specific-shutdown "ERROR: Config file $CONFIG_FILE not found"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Validate config
if [[ -z "${MON_WED_HOUR:-}" ]]; then
	logger -t day-specific-shutdown "ERROR: Config file missing required variables"
	exit 1
fi
if [[ -z "${THU_SUN_HOUR:-}" ]]; then
	logger -t day-specific-shutdown "ERROR: Config file missing required variables"
	exit 1
fi
if [[ -z "${MORNING_END_HOUR:-}" ]]; then
    logger -t day-specific-shutdown "ERROR: Config file missing required variables"
    exit 1
fi

# Get current time and day (fork-free bash builtins)
current_hour=$(printf '%(%H)T' -1)
current_minute=$(printf '%(%M)T' -1)
current_time_minutes=$((10#$current_hour * 60 + 10#$current_minute))
day_of_week=$(printf '%(%u)T' -1)  # 1=Monday, 7=Sunday
day_name=$(printf '%(%A)T' -1)

# Calculate minute thresholds from config
mon_wed_minutes=$((MON_WED_HOUR * 60))
thu_sun_minutes=$((THU_SUN_HOUR * 60))
morning_end_minutes=$((MORNING_END_HOUR * 60))

logger -t day-specific-shutdown "Checking shutdown conditions at $(printf '%(%Y-%m-%d %H:%M:%S)T' -1) - Day: $day_name ($day_of_week), Time: $current_hour:$current_minute"

# Determine if we should shutdown based on day and time
should_shutdown=false

if [[ $day_of_week -ge 1 ]] && [[ $day_of_week -le 3 ]]; then
    # Monday (1), Tuesday (2), Wednesday (3)
    shutdown_start=$mon_wed_minutes
    logger -t day-specific-shutdown "Today is $day_name - checking ${MON_WED_HOUR}:00-0${MORNING_END_HOUR}:00 window"

    if [[ $current_time_minutes -ge $shutdown_start ]] || [[ $current_time_minutes -le $morning_end_minutes ]]; then
        should_shutdown=true
        if [[ $current_time_minutes -ge $shutdown_start ]]; then
            logger -t day-specific-shutdown "Time $current_hour:$current_minute is within evening shutdown window (${MON_WED_HOUR}:00-23:59)"
        else
            logger -t day-specific-shutdown "Time $current_hour:$current_minute is within morning shutdown window (00:00-0${MORNING_END_HOUR}:00)"
        fi
    else
        logger -t day-specific-shutdown "Time $current_hour:$current_minute is outside shutdown window (${MON_WED_HOUR}:00-0${MORNING_END_HOUR}:00)"
    fi
else
    # Thursday (4), Friday (5), Saturday (6), Sunday (7)
    shutdown_start=$thu_sun_minutes
    logger -t day-specific-shutdown "Today is $day_name - checking ${THU_SUN_HOUR}:00-0${MORNING_END_HOUR}:00 window"

    if [[ $current_time_minutes -ge $shutdown_start ]] || [[ $current_time_minutes -le $morning_end_minutes ]]; then
        should_shutdown=true
        if [[ $current_time_minutes -ge $shutdown_start ]]; then
            logger -t day-specific-shutdown "Time $current_hour:$current_minute is within evening shutdown window (${THU_SUN_HOUR}:00-23:59)"
        else
            logger -t day-specific-shutdown "Time $current_hour:$current_minute is within morning shutdown window (00:00-0${MORNING_END_HOUR}:00)"
        fi
    else
        logger -t day-specific-shutdown "Time $current_hour:$current_minute is outside shutdown window (${THU_SUN_HOUR}:00-0${MORNING_END_HOUR}:00)"
    fi
fi

if [[ $should_shutdown == true ]]; then
    printf '%(%Y-%m-%d %H:%M:%S)T: Executing shutdown - current time %s:%s is within shutdown window for %s\n' -1 "$current_hour" "$current_minute" "$day_name"
    logger -t day-specific-shutdown "Executing scheduled shutdown at $(printf '%(%Y-%m-%d %H:%M:%S)T' -1)"

    # If tomorrow is a wake-alarm day (Mon=1, Fri=5, Sat=6, Sun=7), hibernate
    # with an RTC timer so the alarm fires 8 hours later. Hibernate is completely
    # silent and dark — ideal when the PC is in a bedroom. rtcwake -m disk saves
    # state to swap and powers off, then the RTC restores power at wake_epoch.
    #
    # NOTE the -i (--ignore-inhibitors): this is a digital-wellbeing *enforcement*
    # shutdown and must be unbypassable. Without -i, any process holding a block
    # inhibitor — a game, Steam, a video player, or our own controller idle-off
    # watcher — silently denies the hibernate ("Operation denied due to active
    # block inhibitor") and the PC stays up all night. -i overrides all locks.
    tomorrow_dow=$(date -d "tomorrow" +%u)
    case "$tomorrow_dow" in
        1|5|6|7)
            wake_epoch=$(( $(printf '%(%s)T' -1) + 8 * 3600 ))
            logger -t day-specific-shutdown "Tomorrow is alarm day (dow=$tomorrow_dow) — hibernating, RTC wake at epoch $wake_epoch"
            if [[ "${DRY_RUN:-}" == "1" ]]; then
                logger -t day-specific-shutdown "DRY_RUN: would run rtcwake -m no -t $wake_epoch then systemctl hibernate -i"
            else
                /usr/bin/sudo /usr/sbin/rtcwake -m no -t "$wake_epoch"
                /usr/bin/systemctl hibernate -i
            fi
            ;;
        *)
            logger -t day-specific-shutdown "Tomorrow is not an alarm day — powering off normally"
            if [[ "${DRY_RUN:-}" == "1" ]]; then
                logger -t day-specific-shutdown "DRY_RUN: would run systemctl poweroff -i"
            else
                /usr/bin/systemctl poweroff -i
            fi
            ;;
    esac
else
    printf '%(%Y-%m-%d %H:%M:%S)T: Skipping shutdown - not within shutdown window for %s (current: %s:%s)\n' -1 "$day_name" "$current_hour" "$current_minute"
    logger -t day-specific-shutdown "Skipped shutdown - not within shutdown window for $day_name (current: $current_hour:$current_minute)"
fi
EOF

	chmod +x "$check_script"
	echo "✓ Created smart shutdown check script: $check_script"
}

# Function to create the time-boxed override manager (event exceptions like
# watching a live match that runs past the normal shutdown window). Overrides
# are absolute-epoch-bound so they expire on their own; the friction (typed
# confirmation + delay) lives entirely in this CLI, matching the existing
# unlock script's philosophy for the permanent schedule ratchet.
create_override_manager_script() {
	echo ""
	echo "9. Creating Shutdown Override Manager..."
	echo "========================================"

	local overrides_file="/etc/shutdown-schedule-overrides.conf"
	local log_file="/var/log/shutdown-schedule-overrides.log"
	local manager_script="/usr/local/bin/shutdown-override-manager.sh"

	touch "$overrides_file"
	# World-readable (like shutdown-schedule.conf): the i3blocks countdown
	# script runs as the regular user and needs to read active overrides to
	# display them. Only root can write to it (via this manager script).
	chmod 644 "$overrides_file"
	touch "$log_file"
	chmod 600 "$log_file"

	cat >"$manager_script" <<'EOF'
#!/bin/bash
# Shutdown Override Manager
# Registers time-boxed exceptions to the day-specific-shutdown schedule, e.g.
# to watch a live event that runs past the normal shutdown window. Entries are
# absolute-epoch-bound and expire on their own - there is nothing to re-lock.

set -euo pipefail

OVERRIDES_FILE="/etc/shutdown-schedule-overrides.conf"
LOG_FILE="/var/log/shutdown-schedule-overrides.log"
MAX_OVERRIDE_HOURS=12
MAX_ACTIVE_OVERRIDES=3
MIN_REASON_LEN=10
CONFIRM_PHRASE="I am deliberately bypassing my shutdown protection"
DELAY_SECONDS=30

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This command requires sudo." >&2
        exit 1
    fi
}

now_epoch() {
    printf '%(%s)T' -1
}

prune_and_read() {
    # Prints kept (non-expired) lines; overwrites OVERRIDES_FILE with them.
    local now kept=""
    now=$(now_epoch)
    if [[ -f "$OVERRIDES_FILE" ]]; then
        local start_epoch end_epoch created reason
        while IFS='|' read -r start_epoch end_epoch created reason; do
            [[ -n "$start_epoch" ]] || continue
            [[ "$end_epoch" -lt "$now" ]] && continue
            kept+="${start_epoch}|${end_epoch}|${created}|${reason}"$'\n'
        done <"$OVERRIDES_FILE"
    fi
    printf '%s' "$kept" >"$OVERRIDES_FILE"
    printf '%s' "$kept"
}

cmd_list() {
    local kept
    kept="$(prune_and_read)"
    if [[ -z "$kept" ]]; then
        echo "No active or upcoming overrides."
        return 0
    fi
    echo "Active/upcoming overrides:"
    local i=1
    local start_epoch end_epoch created reason
    while IFS='|' read -r start_epoch end_epoch created reason; do
        [[ -n "$start_epoch" ]] || continue
        printf '  [%d] %s -> %s  (reason: %s)\n' \
            "$i" \
            "$(date -d "@$start_epoch" '+%Y-%m-%d %H:%M')" \
            "$(date -d "@$end_epoch" '+%Y-%m-%d %H:%M')" \
            "$reason"
        i=$((i + 1))
    done <<<"$kept"
}

cmd_remove() {
    require_root
    local target="${1:-}"
    [[ -n "$target" ]] || { echo "Usage: $0 remove <line-number-from-list>" >&2; exit 1; }

    local kept
    kept="$(prune_and_read)"
    if [[ -z "$kept" ]]; then
        echo "No overrides to remove." >&2
        exit 1
    fi

    local new_content="" i=1 start_epoch end_epoch created reason removed=false
    while IFS='|' read -r start_epoch end_epoch created reason; do
        [[ -n "$start_epoch" ]] || continue
        if [[ "$i" == "$target" ]]; then
            removed=true
        else
            new_content+="${start_epoch}|${end_epoch}|${created}|${reason}"$'\n'
        fi
        i=$((i + 1))
    done <<<"$kept"

    if [[ "$removed" != true ]]; then
        echo "No override at index $target" >&2
        exit 1
    fi

    printf '%s' "$new_content" >"$OVERRIDES_FILE"
    log "Removed override index $target (by $(logname 2>/dev/null || echo unknown))"
    echo "✓ Removed override $target"
}

cmd_add() {
    require_root
    local start_str="${1:-}" end_str="${2:-}"
    local reason="${*:3}"

    if [[ -z "$start_str" ]] || [[ -z "$end_str" ]] || [[ -z "$reason" ]]; then
        echo "Usage: $0 add '<start datetime>' '<end datetime>' <reason>" >&2
        echo "Example: $0 add '2026-07-10 21:30' '2026-07-11 00:30' 'World Cup match'" >&2
        exit 1
    fi

    if [[ "${#reason}" -lt "$MIN_REASON_LEN" ]]; then
        echo "Reason must be at least $MIN_REASON_LEN characters." >&2
        exit 1
    fi

    local start_epoch end_epoch
    start_epoch=$(date -d "$start_str" +%s) || { echo "Could not parse start datetime: $start_str" >&2; exit 1; }
    end_epoch=$(date -d "$end_str" +%s) || { echo "Could not parse end datetime: $end_str" >&2; exit 1; }

    if [[ "$end_epoch" -le "$start_epoch" ]]; then
        echo "End must be after start." >&2
        exit 1
    fi

    local duration_hours=$(( (end_epoch - start_epoch) / 3600 ))
    if [[ "$duration_hours" -gt "$MAX_OVERRIDE_HOURS" ]]; then
        echo "Override duration (${duration_hours}h) exceeds the max of ${MAX_OVERRIDE_HOURS}h." >&2
        exit 1
    fi

    local kept active_count
    kept="$(prune_and_read)"
    active_count=$(grep -c . <<<"$kept" 2>/dev/null || true)
    active_count="${active_count:-0}"
    if [[ "$active_count" -ge "$MAX_ACTIVE_OVERRIDES" ]]; then
        echo "Already at the max of $MAX_ACTIVE_OVERRIDES active/upcoming overrides. Remove one first." >&2
        cmd_list
        exit 1
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║          SHUTDOWN SCHEDULE OVERRIDE REQUEST                     ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "This suspends the shutdown enforcement you built for yourself during:"
    echo "  $(date -d "@$start_epoch" '+%Y-%m-%d %H:%M') -> $(date -d "@$end_epoch" '+%Y-%m-%d %H:%M') (${duration_hours}h)"
    echo "  Reason: $reason"
    echo ""
    echo "Current overrides:"
    cmd_list
    echo ""
    echo "To confirm this is a deliberate, one-off exception (not just wanting to"
    echo "stay up), type the following phrase exactly:"
    echo ""
    echo "  $CONFIRM_PHRASE"
    echo ""
    read -r -p "> " typed_phrase
    if [[ "$typed_phrase" != "$CONFIRM_PHRASE" ]]; then
        echo "Phrase did not match. Aborting." >&2
        log "ABORTED: confirmation phrase mismatch for window $start_str -> $end_str"
        exit 1
    fi

    echo ""
    echo "Waiting $DELAY_SECONDS seconds before committing (Ctrl+C to cancel)..."
    local i
    for ((i = DELAY_SECONDS; i > 0; i--)); do
        printf "\r  Waiting: %2d seconds remaining..." "$i"
        sleep 1
    done
    echo ""

    local created
    created=$(now_epoch)
    printf '%s|%s|%s|%s\n' "$start_epoch" "$end_epoch" "$created" "$reason" >>"$OVERRIDES_FILE"

    log "ADDED override by $(logname 2>/dev/null || echo unknown) from TTY $(tty 2>/dev/null || echo unknown): $start_str -> $end_str (reason: $reason)"
    echo "✓ Override registered: $(date -d "@$start_epoch" '+%Y-%m-%d %H:%M') -> $(date -d "@$end_epoch" '+%Y-%m-%d %H:%M')"
}

case "${1:-}" in
    add)
        shift
        cmd_add "$@"
        ;;
    list)
        cmd_list
        ;;
    remove)
        shift
        cmd_remove "$@"
        ;;
    *)
        echo "Shutdown Override Manager"
        echo "Usage: $0 {add|list|remove}"
        echo ""
        echo "  add '<start>' '<end>' <reason>   Register a time-boxed exception"
        echo "  list                              Show active/upcoming overrides"
        echo "  remove <index>                    Cancel an override (no friction)"
        echo ""
        cmd_list
        ;;
esac
EOF

	chmod +x "$manager_script"
	echo "✓ Created override manager: $manager_script"
	echo "✓ Overrides file: $overrides_file (root-only)"
	echo "✓ Override log: $log_file"
}

# Function to enable the timer
enable_timer() {
	echo ""
	echo "5. Enabling Shutdown Timer..."
	echo "============================"

	# Reload systemd daemon
	systemctl daemon-reload
	echo "✓ Reloaded systemd daemon"

	# Enable the timer
	systemctl enable day-specific-shutdown.timer
	echo "✓ Enabled day-specific-shutdown timer"

	# Start the timer
	systemctl start day-specific-shutdown.timer
	echo "✓ Started day-specific-shutdown timer"
}

# Function to install the monitor service
install_monitor_service() {
	echo ""
	echo "7. Installing Shutdown Timer Monitor Service..."
	echo "=============================================="

	local monitor_script="/usr/local/bin/shutdown-timer-monitor.sh"
	local monitor_service="/etc/systemd/system/shutdown-timer-monitor.service"
	local monitor_timer="/etc/systemd/system/shutdown-timer-monitor-watchdog.timer"
	local monitor_watchdog_service="/etc/systemd/system/shutdown-timer-monitor-watchdog.service"

	# Create the monitor script
	cat >"$monitor_script" <<'EOF'
#!/bin/bash
# Shutdown timer monitor script
# Watches the day-specific-shutdown timer and re-enables it if disabled
# Also ensures the monitor service itself stays running

set -euo pipefail

LOG_FILE="/var/log/shutdown-timer-monitor.log"
TIMER_NAME="day-specific-shutdown.timer"
SERVICE_NAME="day-specific-shutdown.service"
MONITOR_SERVICE="shutdown-timer-monitor.service"
CHECK_INTERVAL=30

wait_seconds() {
	local timeout_s=$1
	local start_ts end_ts elapsed_s remaining_s

	printf -v start_ts '%(%s)T' -1
	IFS= read -r -t "$timeout_s" || true
	printf -v end_ts '%(%s)T' -1

	elapsed_s=$((end_ts - start_ts))
	if (( elapsed_s < timeout_s )); then
		remaining_s=$((timeout_s - elapsed_s))
		sleep "$remaining_s"
	fi
}

current_epoch() {
	local out_var="${1:-}"
	if [[ -n $out_var ]]; then
		printf -v "$out_var" '%(%s)T' -1
	else
		printf '%(%s)T\n' -1
	fi
}

log_message() {
	local _ts
	local msg
	printf -v _ts '%(%Y-%m-%d %H:%M:%S)T' -1
	printf -v msg '%s [shutdown-monitor] %s' "$_ts" "$1"
	printf '%s\n' "$msg" >&2
	printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

timer_needs_restoration() {
    if ! systemctl is-enabled "$TIMER_NAME" &>/dev/null; then
        log_message "Timer $TIMER_NAME is not enabled"
        return 0
    fi
    if ! systemctl is-active "$TIMER_NAME" &>/dev/null; then
        log_message "Timer $TIMER_NAME is not active"
        return 0
    fi
    if [[ ! -f "/etc/systemd/system/$TIMER_NAME" ]]; then
        log_message "Timer unit file missing"
        return 0
    fi
    if [[ ! -f "/etc/systemd/system/$SERVICE_NAME" ]]; then
        log_message "Service unit file missing"
        return 0
    fi
    if [[ ! -f "/usr/local/bin/day-specific-shutdown-check.sh" ]]; then
        log_message "Check script missing"
        return 0
    fi
    return 1
}

restore_timer() {
    log_message "Shutdown timer tampering detected - initiating restoration"
    systemctl daemon-reload
    if ! systemctl is-enabled "$TIMER_NAME" &>/dev/null; then
        log_message "Re-enabling $TIMER_NAME"
        systemctl enable "$TIMER_NAME" 2>/dev/null || true
    fi
    if ! systemctl is-active "$TIMER_NAME" &>/dev/null; then
        log_message "Re-starting $TIMER_NAME"
        systemctl start "$TIMER_NAME" 2>/dev/null || true
    fi
    if systemctl is-active "$TIMER_NAME" &>/dev/null; then
        log_message "Timer restoration completed successfully"
    else
        log_message "WARNING: Timer restoration may have failed"
    fi
}

monitor_with_dbus() {
	log_message "Starting shutdown timer monitoring with D-Bus events"
	local last_check_ts=0

	if command -v busctl &>/dev/null; then
		busctl monitor --system org.freedesktop.systemd1 2>/dev/null |
			while read -r line; do
				if [[ $line == *"$TIMER_NAME"* || $line == *"$SERVICE_NAME"* ]]; then
					local now_ts
					current_epoch now_ts
					if (( now_ts - last_check_ts < CHECK_INTERVAL )); then
						continue
					fi
					last_check_ts=$now_ts
					log_message "Systemd event detected for shutdown timer"
					if timer_needs_restoration; then
						restore_timer
					fi
				fi
			done
	else
		log_message "busctl not available, falling back to polling"
		monitor_with_polling
	fi
}

monitor_with_polling() {
	log_message "Starting shutdown timer monitoring with polling (interval: ${CHECK_INTERVAL}s)"

	while true; do
		if timer_needs_restoration; then
			restore_timer
		fi
		wait_seconds "$CHECK_INTERVAL"
	done
}

start_monitoring() {
	log_message "=== Shutdown Timer Monitor Started ==="
	log_message "Monitoring timer: $TIMER_NAME"
	log_message "Monitoring service: $SERVICE_NAME"

	if timer_needs_restoration; then
		log_message "Initial check: Timer needs restoration"
		restore_timer
	else
		log_message "Initial check: Timer is properly configured"
	fi

	if command -v busctl &>/dev/null; then
		monitor_with_dbus
	else
		log_message "busctl not available, falling back to polling"
		monitor_with_polling
	fi
}

start_monitoring
EOF

	chmod +x "$monitor_script"
	echo "✓ Created monitor script: $monitor_script"

	# Create the monitor service with RefuseManualStop to prevent manual stopping
	cat >"$monitor_service" <<'EOF'
[Unit]
Description=Shutdown Timer Monitor and Auto-Restore Service
After=network-online.target day-specific-shutdown.timer
Wants=network-online.target
# Make it hard to stop - refuse manual stop/restart
RefuseManualStop=true
RefuseManualStart=false

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/shutdown-timer-monitor.sh
Restart=always
RestartSec=5
# Restart even on success exit
RestartForceExitStatus=0 1 2 SIGTERM SIGKILL
StandardOutput=journal
StandardError=journal
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NoNewPrivileges=false
PrivateTmp=true
MemoryMax=50M
CPUQuota=10%

[Install]
WantedBy=multi-user.target
EOF

	echo "✓ Created monitor service: $monitor_service"

	# Create a watchdog timer that ensures the monitor stays running
	cat >"$monitor_watchdog_service" <<'EOF'
[Unit]
Description=Watchdog for Shutdown Timer Monitor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'systemctl is-active shutdown-timer-monitor.service || systemctl start shutdown-timer-monitor.service'
ExecStart=/bin/bash -c 'systemctl is-active day-specific-shutdown.timer || systemctl start day-specific-shutdown.timer'
EOF

	echo "✓ Created watchdog service: $monitor_watchdog_service"

	cat >"$monitor_timer" <<'EOF'
[Unit]
Description=Watchdog Timer for Shutdown Timer Monitor
After=multi-user.target

[Timer]
OnBootSec=60
OnUnitActiveSec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

	echo "✓ Created watchdog timer: $monitor_timer"

	# Reload and enable everything
	systemctl daemon-reload
	systemctl enable shutdown-timer-monitor.service
	systemctl enable shutdown-timer-monitor-watchdog.timer
	systemctl start shutdown-timer-monitor.service
	systemctl start shutdown-timer-monitor-watchdog.timer
	echo "✓ Enabled and started shutdown-timer-monitor.service"
	echo "✓ Enabled and started shutdown-timer-monitor-watchdog.timer"
}

# Function to test the setup
test_setup() {
	echo ""
	echo "8. Testing Setup..."
	echo "=================="

	echo "Service files:"
	if [[ -f "/etc/systemd/system/day-specific-shutdown.service" ]]; then
		echo "✓ Service file exists"
	else
		echo "✗ Service file missing"
	fi

	if [[ -f "/etc/systemd/system/day-specific-shutdown.timer" ]]; then
		echo "✓ Timer file exists"
	else
		echo "✗ Timer file missing"
	fi

	if [[ -f "/etc/systemd/system/shutdown-timer-monitor.service" ]]; then
		echo "✓ Monitor service file exists"
	else
		echo "✗ Monitor service file missing"
	fi

	echo ""
	echo "Timer status:"
	if systemctl is-enabled day-specific-shutdown.timer &>/dev/null; then
		echo "✓ Timer is enabled"
	else
		echo "✗ Timer is not enabled"
	fi

	if systemctl is-active day-specific-shutdown.timer &>/dev/null; then
		echo "✓ Timer is active"
	else
		echo "✗ Timer is not active"
	fi

	echo ""
	echo "Monitor status:"
	if systemctl is-enabled shutdown-timer-monitor.service &>/dev/null; then
		echo "✓ Monitor is enabled"
	else
		echo "✗ Monitor is not enabled"
	fi

	if systemctl is-active shutdown-timer-monitor.service &>/dev/null; then
		echo "✓ Monitor is active"
	else
		echo "✗ Monitor is not active"
	fi

	echo ""
	echo "Watchdog timer status:"
	if systemctl is-enabled shutdown-timer-monitor-watchdog.timer &>/dev/null; then
		echo "✓ Watchdog timer is enabled"
	else
		echo "✗ Watchdog timer is not enabled"
	fi

	if systemctl is-active shutdown-timer-monitor-watchdog.timer &>/dev/null; then
		echo "✓ Watchdog timer is active"
	else
		echo "✗ Watchdog timer is not active"
	fi

	echo ""
	echo "Config file protection status:"
	local canonical_file
	canonical_file="$(canonical_config_path)"

	if [[ -f $CONFIG_FILE ]]; then
		echo "✓ Config file exists"
		if lsattr "$CONFIG_FILE" 2>/dev/null | grep -q '^....i'; then
			echo "✓ Config file is immutable"
		else
			echo "✗ Config file is NOT immutable"
		fi
	else
		echo "✗ Config file missing"
	fi

	if [[ -n $canonical_file ]] && [[ -f $canonical_file ]]; then
		echo "✓ Canonical copy exists"
	else
		echo "✗ Canonical copy missing"
	fi

	if systemctl is-enabled "guard-file@${GUARD_NAME}.path" &>/dev/null; then
		echo "✓ Config guard path watcher is enabled"
	else
		echo "✗ Config guard path watcher is not enabled"
	fi

	if systemctl is-active "guard-file@${GUARD_NAME}.path" &>/dev/null; then
		echo "✓ Config guard path watcher is active"
	else
		echo "✗ Config guard path watcher is not active"
	fi

	echo ""
	echo "Next scheduled checks:"
	if ! systemctl list-timers day-specific-shutdown.timer --no-pager 2>/dev/null | head -5 | grep day-specific-shutdown; then
		echo "Timer information not available"
	fi
}

# Display the shutdown schedule (used in multiple places)
print_shutdown_schedule() {
	# Convert 24h to 12h format for display
	local mon_wed_12h thu_sun_12h morning_12h
	if [[ $SCHEDULE_MON_WED_HOUR -gt 12 ]]; then
		mon_wed_12h="$((SCHEDULE_MON_WED_HOUR - 12)):00 PM"
	else
		mon_wed_12h="${SCHEDULE_MON_WED_HOUR}:00 AM"
	fi
	if [[ $SCHEDULE_THU_SUN_HOUR -gt 12 ]]; then
		thu_sun_12h="$((SCHEDULE_THU_SUN_HOUR - 12)):00 PM"
	else
		thu_sun_12h="${SCHEDULE_THU_SUN_HOUR}:00 AM"
	fi
	morning_12h="${SCHEDULE_MORNING_END_HOUR}:00 AM"

	echo "Shutdown Schedule:"
	echo "  Monday-Wednesday: ${SCHEDULE_MON_WED_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00 (${mon_wed_12h} to ${morning_12h})"
	echo "  Thursday-Sunday:  ${SCHEDULE_THU_SUN_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00 (${thu_sun_12h} to ${morning_12h})"
}

# Function to show final instructions
show_instructions() {
	echo ""
	echo "================================================="
	echo "Day-Specific Auto-Shutdown Setup Complete"
	echo "================================================="
	echo "Summary:"
	echo "✓ Systemd service created (/etc/systemd/system/day-specific-shutdown.service)"
	echo "✓ Systemd timer created (/etc/systemd/system/day-specific-shutdown.timer)"
	echo "✓ Management script created (/usr/local/bin/day-specific-shutdown-manager.sh)"
	echo "✓ Smart check script created (/usr/local/bin/day-specific-shutdown-check.sh)"
	echo "✓ Timer enabled and started"
	echo "✓ Monitor service installed (protects timer from being disabled)"
	echo "✓ Watchdog timer installed (restarts monitor if stopped)"
	echo "✓ Config file protected (immutable + path watcher + canonical copy)"
	echo ""
	print_shutdown_schedule
	echo ""
	echo "Management commands:"
	echo "  sudo day-specific-shutdown-manager.sh status   - Check status"
	echo "  sudo day-specific-shutdown-manager.sh logs     - View shutdown logs"
	echo ""
	echo "How it works:"
	echo "• Timer checks every 30 minutes during potential shutdown windows"
	echo "• Smart logic determines shutdown eligibility based on day and time"
	echo "• Monitor service watches the timer and re-enables it if disabled"
	echo "• Watchdog timer restarts the monitor every 60 seconds if stopped"
	echo "• Monitor has RefuseManualStop=true to prevent easy stopping"
	echo "• Config file is protected by multiple security layers"
	echo "• There is NO disable option - this is intentional for digital wellbeing"
	echo ""
	echo "WARNING: This will automatically shutdown your PC during designated hours."
	echo "Make sure to save your work before the shutdown windows!"
	echo ""
}

# Function to prompt for confirmation
confirm_setup() {
	echo ""
	echo "WARNING: Day-Specific Auto-Shutdown Confirmation"
	echo "==============================================="
	echo "This will set up your PC to automatically shutdown during specific time windows."
	echo ""
	print_shutdown_schedule
	echo ""
	echo "Important considerations:"
	echo "- Any unsaved work will be lost during shutdown windows"
	echo "- Running processes will be terminated"
	echo "- Downloads/uploads in progress will be interrupted"
	echo "- You'll need to manually power on your PC each day"
	echo "- Timer checks every 30 minutes during potential shutdown windows"
	echo "- There is NO disable option - this is protected by a monitor service"
	echo ""
	read -r -p "Do you want to proceed? (y/N): " confirm

	case "$confirm" in
	[yY] | [yY][eE][sS])
		echo "Proceeding with setup..."
		return 0
		;;
	*)
		echo "Setup cancelled."
		exit 0
		;;
	esac
}

# Main execution flow for enable
enable_midnight_shutdown() {
	echo "Day-Specific Auto-Shutdown Setup for Arch Linux"
	echo "==============================================="
	echo "Current Date: $(date)"
	echo "User: $ACTUAL_USER"
	echo "Target user: $ACTUAL_USER"
	echo "User home: $USER_HOME"

	# Check if trying to cheat by making schedule more lenient
	check_schedule_protection

	# Confirm setup
	confirm_setup

	# Create config file (shared with i3blocks countdown script)
	create_shutdown_config

	# Create config guard (path watcher, enforcement, unlock script)
	create_config_guard

	# Create systemd files
	create_shutdown_service
	create_shutdown_timer
	create_management_script
	create_shutdown_check_script
	create_override_manager_script

	# Enable and start timer
	enable_timer

	# Install monitor service (protects timer from being disabled)
	install_monitor_service

	# Test setup
	test_setup

	# NOTE: this used to `chattr +i` its own source ("lock this setup script so
	# values + checks can't be silently edited"). Do NOT reintroduce that: making
	# a git-tracked file immutable breaks git. pre-commit clears unstaged changes
	# with `git checkout -- .`; that unlink fails with "Operation not permitted"
	# on an immutable file, the context manager aborts, and the restore never
	# runs — silently reverting your OTHER unstaged edits on every commit/push.
	#
	# Enforcement does not depend on it: /etc/shutdown-schedule.conf is chattr +i,
	# guard-lib keeps a canonical snapshot + path watcher that re-enforces it, the
	# monitor service protects the timer, and screen_locker's ratchet only accepts
	# same-or-stricter values. Editing this source changes nothing until setup is
	# re-run as root, which rewrites the guarded config anyway.

	# Show instructions
	show_instructions
}

# Parse command line arguments
case "${1:-enable}" in
"enable")
	check_sudo "$@"
	enable_midnight_shutdown
	;;
"status")
	check_sudo "$@"
	show_current_status
	;;
"help" | "-h" | "--help")
	show_usage
	;;
*)
	echo "Error: Unknown command '$1'"
	echo ""
	show_usage
	exit 1
	;;
esac
