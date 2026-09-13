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
# Bounded, never 0 (= infinity). On 2026-09-12 the lock action hung inside
# openrgb; with an infinite start timeout the oneshot sat in "activating" all
# night and every later per-minute timer tick was a no-op against a live
# desktop. A hung tick now dies here and the next minute gets a fresh run.
# The lock action itself finishes in seconds; 180s is generous.
TimeoutStartSec=180
# The timer fires every minute all day; without this PID 1 alone would write
# "Starting/Finished/Deactivated" 4k times a day. notice keeps the check
# script's own logger(1) lines (user.notice) and drops PID 1's info chatter.
LogLevelMax=notice
# ...and stdout/stderr of the check + lock scripts is stamped notice so it
# survives that cap (the default stamp is info, which would be dropped).
SyslogLevel=notice
StandardOutput=journal
StandardError=journal
EOF

	echo "✓ Created systemd service: $service_file"
}

# Function to create the shutdown timer.
#
# The timer fires EVERY MINUTE, ALL DAY. The check script is the only thing
# that knows the window (it reads /etc/shutdown-schedule.conf on every run), so
# the unit carries no copy of the schedule that could drift from it. Two real
# drifts motivated this: the timer was once generated from this script's
# SCHEDULE_* constants while the config said something else (23:00-00:00
# unenforced every night), and after that was fixed by reading the config at
# generation time, screen_locker's sick-day feature rewrote the config to 20:00
# with a timer whose earliest entry was still 23:00 (2026-09-13). Any hour in
# 0-24 is a legal config value, so the only window that can never be out of
# date is the whole day. The out-of-window run is fork-free and costs nothing.
#
# Per-minute granularity matters inside the window too: a 30-minute tick is
# 30 minutes of usable machine after any event that drops enforcement (a
# power-cycle, a lock action that timed out).
create_shutdown_timer() {
	echo ""
	echo "4. Creating Systemd Shutdown Timer..."
	echo "==================================="

	local timer_file="/etc/systemd/system/day-specific-shutdown.timer"

	cat >"$timer_file" <<EOF
[Unit]
Description=Timer for automatic PC shutdown with day-specific windows
Requires=day-specific-shutdown.service

[Timer]
OnCalendar=*-*-* *:*:00
Persistent=false
AccuracySec=1s
WakeSystem=false
RandomizedDelaySec=0

[Install]
WantedBy=timers.target
EOF

	echo "✓ Created systemd timer: $timer_file"
	echo "  Timer fires every minute; the window comes from $CONFIG_FILE at run time"
}

# Regenerate the timer, the service and the check script — everything that is
# NOT the schedule — then reload and restart the timer.
#
# Deliberately separate from `enable`: a full re-run goes through the ratchet in
# check_schedule_protection and rewrites the guarded config from this script's
# SCHEDULE_* constants. With constants at 21 and the live config at 20 (a sick
# day) that would move the curfew — a schedule change nobody asked for — just to
# ship a unit-file fix. This path touches no schedule value at all, which is
# what makes it the safe way to deploy a change to the units or the check.
sync_shutdown_timer() {
	if [[ ! -r "$CONFIG_FILE" ]]; then
		echo "Error: $CONFIG_FILE not found - run '$0 enable' first" >&2
		return 1
	fi

	create_shutdown_service
	create_shutdown_timer
	create_shutdown_check_script
	systemctl daemon-reload
	systemctl restart day-specific-shutdown.timer
	echo "✓ Units and check script regenerated; schedule in $CONFIG_FILE untouched"
	systemctl list-timers day-specific-shutdown.timer --no-pager | head -3
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
