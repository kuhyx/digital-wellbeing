#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Function to create/update shutdown schedule config file (shared with
# i3blocks countdown). Mechanical protection (canonical snapshot, chattr,
# path watcher) is guard-lib's job via create_config_guard() below; this
# function only decides what content should exist.
create_shutdown_config() {
	echo ""
	echo "1. Creating Shutdown Schedule Config..."
	echo "======================================="

	local new_content
	new_content="$(
		cat <<EOF
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
