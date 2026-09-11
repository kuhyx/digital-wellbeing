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

# Function to create the shutdown timer.
#
# The OnCalendar list is derived from the LIVE config at $CONFIG_FILE, not from
# this script's SCHEDULE_* constants. Those two drift: the constants say 21, but
# screen_locker's sick-day feature rewrites /etc/shutdown-schedule.conf in place
# (it said 23 on 2026-09-11) without regenerating this unit. The installed timer
# had been generated back when the constant was 24, so its earliest entry was
# 00:00 and the whole 23:00-00:00 hour was unenforced every single night —
# the check script was reading 23 while the timer never woke it before midnight.
# One source of truth: whatever the guarded config currently says.
#
# Granularity is every minute inside the window (HH:*:00) rather than :00/:30.
# The check script is cheap, and a 30-minute tick is 30 minutes of usable
# machine after any event that drops enforcement (a power-cycle, a failed
# lock). Outside the window the timer never fires, so the journal stays quiet.
create_shutdown_timer() {
	echo ""
	echo "4. Creating Systemd Shutdown Timer..."
	echo "==================================="

	local timer_file="/etc/systemd/system/day-specific-shutdown.timer"
	local mon_wed thu_sun morning_end

	# Read the live, guarded config; fall back to this script's constants only
	# on a first install where the config does not exist yet.
	if [[ -r "$CONFIG_FILE" ]]; then
		mon_wed="$(sed -n 's/^MON_WED_HOUR=\([0-9]\+\).*/\1/p' "$CONFIG_FILE" | tail -1)"
		thu_sun="$(sed -n 's/^THU_SUN_HOUR=\([0-9]\+\).*/\1/p' "$CONFIG_FILE" | tail -1)"
		morning_end="$(sed -n 's/^MORNING_END_HOUR=\([0-9]\+\).*/\1/p' "$CONFIG_FILE" | tail -1)"
	fi
	mon_wed="${mon_wed:-$SCHEDULE_MON_WED_HOUR}"
	thu_sun="${thu_sun:-$SCHEDULE_THU_SUN_HOUR}"
	morning_end="${morning_end:-$SCHEDULE_MORNING_END_HOUR}"

	# Calculate earliest shutdown hour (minimum of MON_WED and THU_SUN)
	local earliest_hour=$mon_wed
	if [[ $thu_sun -lt $earliest_hour ]]; then
		earliest_hour=$thu_sun
	fi

	{
		cat <<EOF
[Unit]
Description=Timer for automatic PC shutdown with day-specific windows
Requires=day-specific-shutdown.service

[Timer]
EOF
		# Evening hours: earliest shutdown hour through 23. An hour of 24 means
		# "midnight", i.e. no evening entries at all — seq handles that by
		# producing an empty range.
		local hour
		for hour in $(seq "$earliest_hour" 23); do
			printf 'OnCalendar=*-*-* %02d:*:00\n' "$hour"
		done

		# Morning hours: 00:00 up to (not including) MORNING_END_HOUR. At
		# exactly MORNING_END_HOUR the window is already over, so no entry.
		for ((hour = 0; hour < morning_end; hour++)); do
			printf 'OnCalendar=*-*-* %02d:*:00\n' "$hour"
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
	echo "  Timer covers: ${earliest_hour}:00 to 0${morning_end}:00 (every minute)"
}

# Regenerate ONLY the timer from the live config, then reload and restart it.
#
# Deliberately separate from `enable`: a full re-run goes through the ratchet in
# check_schedule_protection, which compares this script's SCHEDULE_* constants
# against the live config and accepts anything same-or-stricter. With constants
# at 21 and the live config at 23 that would silently move the curfew two hours
# earlier — a schedule change nobody asked for — just to fix a unit file. This
# path touches no schedule value at all.
sync_shutdown_timer() {
	if [[ ! -r "$CONFIG_FILE" ]]; then
		echo "Error: $CONFIG_FILE not found - run '$0 enable' first" >&2
		return 1
	fi

	create_shutdown_timer
	systemctl daemon-reload
	systemctl restart day-specific-shutdown.timer
	echo "✓ Timer resynced from $CONFIG_FILE and restarted"
	systemctl list-timers day-specific-shutdown.timer --no-pager | head -3
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
