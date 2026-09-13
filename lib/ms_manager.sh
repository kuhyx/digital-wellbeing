#!/usr/bin/env bash
# Helpers sourced by the entry script: the user-facing management CLI
# (/usr/local/bin/day-specific-shutdown-manager.sh). Split out of
# ms_units.sh to keep both under the 250-line cap.

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
