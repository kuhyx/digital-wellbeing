#!/bin/bash
# Script to set up automatic PC shutdown with day-specific time windows
# Monday-Wednesday: Shutdown between 21:00-05:00
# Thursday-Sunday: Shutdown between 22:00-05:00
# Handles sudo privileges automatically

set -e # Exit on any error

# Source common library for shared functions
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# Schedule constants (single source of truth for this script)
# These values are written to /etc/shutdown-schedule.conf during setup
SCHEDULE_MON_WED_HOUR=24
SCHEDULE_THU_SUN_HOUR=24
SCHEDULE_MORNING_END_HOUR=0

# ============================================================================
# SCHEDULE PROTECTION MECHANISM
# ============================================================================
# This prevents easy "cheating" by modifying the script values and re-running.
# If a canonical config already exists, the script compares against it and
# BLOCKS installation if the new values would make the schedule MORE LENIENT
# (i.e., later shutdown hours or earlier morning end).
# ============================================================================

CANONICAL_CONFIG="/usr/local/share/locked-shutdown-schedule.conf"

# Check if trying to make schedule more lenient (later shutdown / earlier morning end)
check_schedule_protection() {
	# Skip check if no canonical config exists (first install)
	if [[ ! -f $CANONICAL_CONFIG ]]; then
		return 0
	fi

	# Load canonical values
	local canonical_mon_wed canonical_thu_sun canonical_morning_end
	# shellcheck source=/dev/null
	source "$CANONICAL_CONFIG" 2>/dev/null || return 0
	canonical_mon_wed="${MON_WED_HOUR:-}"
	canonical_thu_sun="${THU_SUN_HOUR:-}"
	canonical_morning_end="${MORNING_END_HOUR:-}"

	# If canonical values are empty, skip check
	if [[ -z $canonical_mon_wed ]] || [[ -z $canonical_thu_sun ]] || [[ -z $canonical_morning_end ]]; then
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

	# Check config file protection status
	echo "Config File Protection Status:"
	local config_file="/etc/shutdown-schedule.conf"
	local canonical_file="/usr/local/share/locked-shutdown-schedule.conf"

	if [[ -f $config_file ]]; then
		echo "✓ Config file exists"
		# Check immutable attribute
		if lsattr "$config_file" 2>/dev/null | grep -q '^....i'; then
			echo "✓ Config file is immutable (chattr +i)"
		else
			echo "✗ Config file is NOT immutable"
		fi
	else
		echo "✗ Config file missing"
	fi

	if [[ -f $canonical_file ]]; then
		echo "✓ Canonical copy exists"
	else
		echo "✗ Canonical copy missing"
	fi

	if systemctl is-enabled shutdown-schedule-guard.path &>/dev/null; then
		echo "✓ Config path watcher is enabled"
		if systemctl is-active shutdown-schedule-guard.path &>/dev/null; then
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
}

# Function to create shutdown schedule config file (shared with i3blocks countdown)
# Also creates a canonical (protected) copy and sets immutable attribute
create_shutdown_config() {
	echo ""
	echo "1. Creating Shutdown Schedule Config..."
	echo "======================================="

	local config_file="/etc/shutdown-schedule.conf"
	local canonical_file="/usr/local/share/locked-shutdown-schedule.conf"

	# Remove immutable attribute if it exists (to allow update)
	chattr -i "$config_file" 2>/dev/null || true
	chattr -i "$canonical_file" 2>/dev/null || true

	cat >"$config_file" <<EOF
# Shutdown schedule configuration
# This file is managed by setup_midnight_shutdown.sh
# Used by: day-specific-shutdown-check.sh, shutdown_countdown.sh (i3blocks)
#
# WARNING: This file is protected by:
#   1. Immutable attribute (chattr +i)
#   2. Canonical copy at /usr/local/share/locked-shutdown-schedule.conf
#   3. Path watcher service that auto-restores if modified
#
# Modifications to this file will be automatically reverted.

# Shutdown hour for Monday-Wednesday (24-hour format)
MON_WED_HOUR=${SCHEDULE_MON_WED_HOUR}

# Shutdown hour for Thursday-Sunday (24-hour format)
THU_SUN_HOUR=${SCHEDULE_THU_SUN_HOUR}

# Morning end hour (shutdown window ends at this hour)
MORNING_END_HOUR=${SCHEDULE_MORNING_END_HOUR}
EOF

	chmod 644 "$config_file"
	echo "✓ Created shutdown schedule config: $config_file"

	# Create canonical (protected) copy
	install -m 644 -D "$config_file" "$canonical_file"
	echo "✓ Created canonical copy: $canonical_file"

	# Set immutable attribute on both files
	chattr +i "$config_file" || echo "⚠ Warning: Could not set immutable attribute on $config_file"
	chattr +i "$canonical_file" || echo "⚠ Warning: Could not set immutable attribute on $canonical_file"
	echo "✓ Set immutable attribute (chattr +i) on config files"
}

# Function to create config guard (path watcher + enforcement + unlock script)
create_config_guard() {
	echo ""
	echo "2. Creating Config Guard (Path Watcher + Enforcement)..."
	echo "========================================================"

	local enforce_script="/usr/local/sbin/enforce-shutdown-schedule.sh"
	# Obscure name for unlock script - not documented anywhere
	local unlock_script="/usr/local/sbin/.sd-sched-mgmt"
	local guard_service="/etc/systemd/system/shutdown-schedule-guard.service"
	local guard_path="/etc/systemd/system/shutdown-schedule-guard.path"

	# Create enforcement script
	cat >"$enforce_script" <<'EOF'
#!/bin/bash
# Enforce canonical /etc/shutdown-schedule.conf contents
# This script restores the config from canonical copy if tampered

set -euo pipefail

CANONICAL_SOURCE="/usr/local/share/locked-shutdown-schedule.conf"
TARGET="/etc/shutdown-schedule.conf"
LOG_FILE="/var/log/shutdown-schedule-guard.log"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

if [[ ! -f $CANONICAL_SOURCE ]]; then
    log "Canonical config not found at $CANONICAL_SOURCE; aborting enforcement"
    exit 0
fi

# Remove immutable attr to check/restore
chattr -i -a "$TARGET" 2>/dev/null || true

if ! cmp -s "$CANONICAL_SOURCE" "$TARGET"; then
    log "CONFIG TAMPERING DETECTED – restoring $TARGET from canonical copy"
    cp "$CANONICAL_SOURCE" "$TARGET"
    chmod 644 "$TARGET"
    log "Config restored successfully"
else
    log "No drift detected (contents identical)"
fi

# Re-apply immutable attribute
chattr +i "$TARGET" || log "Failed to set immutable attribute"

log "Enforcement complete"
EOF

	chmod +x "$enforce_script"
	echo "✓ Created enforcement script: $enforce_script"

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
CONFIG_FILE="/etc/shutdown-schedule.conf"
CANONICAL_FILE="/usr/local/share/locked-shutdown-schedule.conf"
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

# Log the unlock attempt
log "=== UNLOCK ATTEMPT by $(logname 2>/dev/null || echo 'unknown') from TTY $(tty 2>/dev/null || echo 'unknown') ==="

# Load current values
OLD_MON_WED=""
OLD_THU_SUN=""
OLD_MORNING_END=""
if [[ -f "$CANONICAL_FILE" ]]; then
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

# Stop the path watcher temporarily
systemctl stop shutdown-schedule-guard.path 2>/dev/null || true

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
        systemctl start shutdown-schedule-guard.path 2>/dev/null || true
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

# Restart path watcher
systemctl start shutdown-schedule-guard.path 2>/dev/null || true

log "Config updated and re-locked by user"

echo ""
echo "✓ Config file updated and re-protected"
echo "✓ Canonical copy updated"
echo "✓ Path watcher re-enabled"
echo ""
echo "New schedule (will take effect on next timer check):"
source "$CONFIG_FILE" 2>/dev/null || true
echo "  Monday-Wednesday: ${MON_WED_HOUR:-??}:00 - 0${MORNING_END_HOUR:-?}:00"
echo "  Thursday-Sunday:  ${THU_SUN_HOUR:-??}:00 - 0${MORNING_END_HOUR:-?}:00"
echo ""
EOF

	chmod +x "$unlock_script"
	# Silently create unlock script - do not announce its existence

	# Create path watcher unit
	cat >"$guard_path" <<'EOF'
[Unit]
Description=Watch /etc/shutdown-schedule.conf and trigger enforcement

[Path]
PathChanged=/etc/shutdown-schedule.conf
Unit=shutdown-schedule-guard.service

[Install]
WantedBy=multi-user.target
EOF

	echo "✓ Created path watcher: $guard_path"

	# Create enforcement service
	cat >"$guard_service" <<'EOF'
[Unit]
Description=Enforce canonical /etc/shutdown-schedule.conf contents
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/enforce-shutdown-schedule.sh
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF

	echo "✓ Created guard service: $guard_service"

	# Reload and enable
	systemctl daemon-reload
	systemctl enable --now shutdown-schedule-guard.path
	echo "✓ Enabled and started shutdown-schedule-guard.path"

	# Run initial enforcement
	"$enforce_script" || echo "⚠ Warning: Initial enforcement returned non-zero"
	echo "✓ Ran initial enforcement"
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

# Load config
if [[ ! -f "$CONFIG_FILE" ]]; then
    logger -t day-specific-shutdown "ERROR: Config file $CONFIG_FILE not found"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Validate config
if [[ -z "${MON_WED_HOUR:-}" ]] || [[ -z "${THU_SUN_HOUR:-}" ]] || [[ -z "${MORNING_END_HOUR:-}" ]]; then
    logger -t day-specific-shutdown "ERROR: Config file missing required variables"
    exit 1
fi

# Get current time and day
current_hour=$(date +%H)
current_minute=$(date +%M)
current_time_minutes=$((10#$current_hour * 60 + 10#$current_minute))
day_of_week=$(date +%u)  # 1=Monday, 7=Sunday
day_name=$(date +%A)

# Calculate minute thresholds from config
mon_wed_minutes=$((MON_WED_HOUR * 60))
thu_sun_minutes=$((THU_SUN_HOUR * 60))
morning_end_minutes=$((MORNING_END_HOUR * 60))

logger -t day-specific-shutdown "Checking shutdown conditions at $(date) - Day: $day_name ($day_of_week), Time: $current_hour:$current_minute"

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
    echo "$(date): Executing shutdown - current time $current_hour:$current_minute is within shutdown window for $day_name"
    logger -t day-specific-shutdown "Executing scheduled shutdown at $(date)"
    /usr/bin/systemctl poweroff
else
    echo "$(date): Skipping shutdown - not within shutdown window for $day_name (current: $current_hour:$current_minute)"
    logger -t day-specific-shutdown "Skipped shutdown - not within shutdown window for $day_name (current: $current_hour:$current_minute)"
fi
EOF

	chmod +x "$check_script"
	echo "✓ Created smart shutdown check script: $check_script"
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

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE" >&2
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

log_message "=== Shutdown Timer Monitor Started ==="
log_message "Monitoring timer: $TIMER_NAME"

if timer_needs_restoration; then
    log_message "Initial check: Timer needs restoration"
    restore_timer
else
    log_message "Initial check: Timer is properly configured"
fi

while true; do
    if timer_needs_restoration; then
        restore_timer
    fi
    sleep "$CHECK_INTERVAL"
done
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
OnUnitActiveSec=60
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
	local config_file="/etc/shutdown-schedule.conf"
	local canonical_file="/usr/local/share/locked-shutdown-schedule.conf"

	if [[ -f $config_file ]]; then
		echo "✓ Config file exists"
		if lsattr "$config_file" 2>/dev/null | grep -q '^....i'; then
			echo "✓ Config file is immutable"
		else
			echo "✗ Config file is NOT immutable"
		fi
	else
		echo "✗ Config file missing"
	fi

	if [[ -f $canonical_file ]]; then
		echo "✓ Canonical copy exists"
	else
		echo "✗ Canonical copy missing"
	fi

	if systemctl is-enabled shutdown-schedule-guard.path &>/dev/null; then
		echo "✓ Config guard path watcher is enabled"
	else
		echo "✗ Config guard path watcher is not enabled"
	fi

	if systemctl is-active shutdown-schedule-guard.path &>/dev/null; then
		echo "✓ Config guard path watcher is active"
	else
		echo "✗ Config guard path watcher is not active"
	fi

	echo ""
	echo "Next scheduled checks:"
	systemctl list-timers day-specific-shutdown.timer --no-pager 2>/dev/null | head -5 | grep day-specific-shutdown || echo "Timer information not available"
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

	# Enable and start timer
	enable_timer

	# Install monitor service (protects timer from being disabled)
	install_monitor_service

	# Test setup
	test_setup

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
