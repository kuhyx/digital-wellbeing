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

# HH:MM from a *_MINUTES value, else from a legacy *_HOUR value.
schedule_hhmm() {
    local minutes="$1" hour="$2"
    if [[ "$minutes" =~ ^[0-9]+$ ]]; then
        printf '%02d:%02d' "$((10#$minutes / 60))" "$((10#$minutes % 60))"
    elif [[ "$hour" =~ ^[0-9]+$ ]]; then
        printf '%02d:00' "$((10#$hour))"
    else
        printf '??'
    fi
}

print_schedule() {
    load_config
    local morning
    morning="$(schedule_hhmm "${MORNING_END_MINUTES:-}" "${MORNING_END_HOUR:-}")"
    echo "Shutdown Schedule:"
    echo "  Monday-Wednesday: $(schedule_hhmm "${MON_WED_MINUTES:-}" "${MON_WED_HOUR:-}")-${morning}"
    echo "  Thursday-Sunday:  $(schedule_hhmm "${THU_SUN_MINUTES:-}" "${THU_SUN_HOUR:-}")-${morning}"
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
