#!/usr/bin/env bash
# Helpers sourced by the entry script.

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
