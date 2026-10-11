#!/bin/bash
# Midnight Auto-Shutdown Manager
# Provides easy management of the midnight shutdown feature

TIMER_NAME="midnight-shutdown.timer"
SERVICE_NAME="midnight-shutdown.service"

show_status() {
    echo "Midnight Auto-Shutdown Status"
    echo "============================"

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
    echo "Next scheduled shutdown:"
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
        echo "Midnight Auto-Shutdown Logs"
        echo "=========================="
        journalctl -u "$SERVICE_NAME" --no-pager -n 20
        ;;
    *)
        echo "Midnight Auto-Shutdown Manager"
        echo "Usage: $0 {status|logs}"
        echo ""
        echo "Commands:"
        echo "  status   - Show current status and next shutdown time"
        echo "  logs     - Show recent shutdown logs"
        echo ""
        show_status
        ;;
esac
