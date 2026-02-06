#!/bin/bash
# Script to monitor PC startup times on specific days
# Checks if PC was turned on between 5AM-8AM on Monday, Friday, Saturday, Sunday
# Handles sudo privileges automatically

set -e # Exit on any error

# Source common library for shared functions
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# Parse interactive/help arguments
parse_interactive_args "$@"
shift "$COMMON_ARGS_SHIFT"

echo "PC Startup Time Monitor for Arch Linux"
echo "======================================"
echo "Current Date: $(date)"
echo "User: $(get_actual_user)"
if [[ $INTERACTIVE_MODE == "true" ]]; then
  echo "Mode: Interactive (prompts enabled)"
else
  echo "Mode: Automatic (auto-yes, use --interactive for prompts)"
fi

# Get the actual user (even when running with sudo)
ACTUAL_USER="$(get_actual_user)"
USER_HOME="$(get_actual_user_home)"

echo "Target user: $ACTUAL_USER"
echo "User home: $USER_HOME"

# Function to check if today is a monitored day
is_monitored_day() {
  local day_of_week
  day_of_week=$(date +%u) # 1=Monday, 7=Sunday

  # Check if today is Monday (1), Friday (5), Saturday (6), or Sunday (7)
  if [[ $day_of_week == "1" ]] || [[ $day_of_week == "5" ]] || [[ $day_of_week == "6" ]] || [[ $day_of_week == "7" ]]; then
    return 0 # Yes, it's a monitored day
  else
    return 1 # No, it's not a monitored day
  fi
}

# Function to check if current time is between 5AM and 8AM
is_current_time_in_window() {
  local current_hour current_hour_num
  current_hour=$(date +%H)
  current_hour_num=$((10#$current_hour)) # Convert to decimal to avoid octal issues

  if [[ $current_hour_num -ge 5 ]] && [[ $current_hour_num -lt 8 ]]; then
    return 0 # Yes, current time is in the 5AM-8AM window
  else
    return 1 # No, current time is outside the window
  fi
}

# Function to check if PC was booted between 5AM-8AM today
was_booted_in_window_today() {
  local today boot_time
  today=$(date +%Y-%m-%d)
  boot_time=""

  # Get the last boot time using multiple methods for reliability
  if command -v uptime &> /dev/null; then
    # Method 1: Calculate boot time from uptime
    local uptime_seconds
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2> /dev/null || echo "0")
    if [[ $uptime_seconds -gt 0 ]]; then
      boot_time=$(date -d "@$(($(date +%s) - uptime_seconds))" +"%Y-%m-%d %H:%M:%S")
    fi
  fi

  # Method 2: Use systemd if available (fallback)
  if [[ -z $boot_time ]] && command -v systemctl &> /dev/null; then
    boot_time=$(systemd-analyze | grep "Startup finished" | sed -n 's/.*finished in .* = \(.*\)$/\1/p' 2> /dev/null || echo "")
    if [[ -n $boot_time ]]; then
      # This gives us relative time, need to calculate absolute time
      local current_time uptime_sec
      current_time=$(date +%s)
      uptime_sec=$(awk '{print int($1)}' /proc/uptime 2> /dev/null || echo "0")
      boot_time=$(date -d "@$((current_time - uptime_sec))" +"%Y-%m-%d %H:%M:%S")
    fi
  fi

  # Method 3: Use who -b (fallback)
  if [[ -z $boot_time ]] && command -v who &> /dev/null; then
    boot_time=$(who -b | awk '{print $3, $4}' 2> /dev/null || echo "")
    if [[ -n $boot_time ]]; then
      boot_time="$today $boot_time"
    fi
  fi

  # Method 4: Use /proc/uptime as final fallback
  if [[ -z $boot_time ]]; then
    local uptime_seconds
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2> /dev/null || echo "0")
    boot_time=$(date -d "@$(($(date +%s) - uptime_seconds))" +"%Y-%m-%d %H:%M:%S")
  fi

  echo "Boot time detected: $boot_time"

  # Check if boot time is from today
  local boot_date
  boot_date=$(echo "$boot_time" | cut -d' ' -f1)
  if [[ $boot_date != "$today" ]]; then
    echo "PC was not booted today (boot date: $boot_date, today: $today)"
    return 1 # Not booted today
  fi

  # Extract hour from boot time
  local boot_hour boot_hour_num
  boot_hour=$(echo "$boot_time" | cut -d' ' -f2 | cut -d':' -f1)
  boot_hour_num=$((10#$boot_hour)) # Convert to decimal

  echo "Boot hour: $boot_hour_num"

  # Check if boot time was between 5AM (5) and 8AM (7, since we want before 8AM)
  if [[ $boot_hour_num -ge 5 ]] && [[ $boot_hour_num -lt 8 ]]; then
    echo "PC was booted in the expected window (5AM-8AM)"
    return 0 # Yes, booted in window
  else
    echo "PC was NOT booted in the expected window (5AM-8AM)"
    return 1 # No, not booted in window
  fi
}

# Function to show notification/warning
show_startup_warning() {
  local day_name current_time today
  day_name=$(date +%A)
  current_time=$(date +"%H:%M")
  today=$(date +%Y-%m-%d)

  echo ""
  echo "⚠️  PC STARTUP TIME WARNING"
  echo "=========================="
  echo "Date: $today ($day_name)"
  echo "Current time: $current_time"
  echo ""
  echo "This PC was expected to be turned on between 5:00 AM and 8:00 AM today,"
  echo "but it was not turned on during that time window."
  echo ""
  echo "Expected: Monday, Friday, Saturday, Sunday between 5:00-8:00 AM"
  echo "Actual: PC was turned on outside the expected window"
  echo ""

  # Log the warning
  logger -t pc-startup-monitor "WARNING: PC was not turned on during expected window (5AM-8AM) on $day_name $today"

  # Try to show desktop notification if possible
  if command -v notify-send &> /dev/null && [[ -n $DISPLAY ]]; then
    if [[ $EUID -eq 0 ]]; then
      # Running as root, send notification as user
      sudo -u "$ACTUAL_USER" DISPLAY="$DISPLAY" notify-send "PC Startup Warning" "PC was not turned on between 5AM-8AM as expected on $day_name" --urgency=normal --expire-time=10000 2> /dev/null || true
    else
      notify-send "PC Startup Warning" "PC was not turned on between 5AM-8AM as expected on $day_name" --urgency=normal --expire-time=10000 2> /dev/null || true
    fi
  fi

  echo "This warning has been logged to the system journal."
  echo "You can view startup logs with: journalctl -t pc-startup-monitor"
  echo ""
}

# Function to create the monitoring service
create_monitoring_service() {
  echo ""
  echo "1. Creating PC Startup Monitor Service..."
  echo "======================================="

  local service_file="/etc/systemd/system/pc-startup-monitor.service"

  cat > "$service_file" << 'EOF'
[Unit]
Description=PC Startup Time Monitor
After=multi-user.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pc-startup-check.sh
StandardOutput=journal
StandardError=journal
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

  echo "✓ Created monitoring service: $service_file"
}

# Function to create the monitoring timer
create_monitoring_timer() {
  echo ""
  echo "2. Creating PC Startup Monitor Timer..."
  echo "====================================="

  local timer_file="/etc/systemd/system/pc-startup-monitor.timer"

  cat > "$timer_file" << 'EOF'
[Unit]
Description=Timer for PC startup monitoring
Requires=pc-startup-monitor.service

[Timer]
OnCalendar=*-*-* 08:30:00
Persistent=false
AccuracySec=1m

[Install]
WantedBy=timers.target
EOF

  echo "✓ Created monitoring timer: $timer_file"
}

# Function to create the main monitoring script
create_monitoring_script() {
  echo ""
  echo "3. Creating PC Startup Monitor Script..."
  echo "======================================"

  local script_file="/usr/local/bin/pc-startup-check.sh"

  cat > "$script_file" << 'EOF'
#!/bin/bash
# PC Startup Time Monitor Check Script
# Monitors if PC was turned on during expected hours on specific days

# Function to check if today is a monitored day
is_monitored_day() {
  local day_of_week
  day_of_week=$(date +%u)  # 1=Monday, 7=Sunday
    
    # Check if today is Monday (1), Friday (5), Saturday (6), or Sunday (7)
    if [[ "$day_of_week" == "1" ]] || [[ "$day_of_week" == "5" ]] || [[ "$day_of_week" == "6" ]] || [[ "$day_of_week" == "7" ]]; then
        return 0  # Yes, it's a monitored day
    else
        return 1  # No, it's not a monitored day
    fi
}

# Function to check if current time is between 5AM and 8AM
is_current_time_in_window() {
  local current_hour current_hour_num
  current_hour=$(date +%H)
  current_hour_num=$((10#$current_hour))
    
    if [[ $current_hour_num -ge 5 ]] && [[ $current_hour_num -lt 8 ]]; then
        return 0  # Yes, current time is in the 5AM-8AM window
    else
        return 1  # No, current time is outside the window
    fi
}

# Function to check if PC was booted between 5AM-8AM today
was_booted_in_window_today() {
  local today boot_time
  today=$(date +%Y-%m-%d)
    
  # Calculate boot time from uptime
  local uptime_seconds
  uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
  boot_time=$(date -d "@$(($(date +%s) - uptime_seconds))" +"%Y-%m-%d %H:%M:%S")
    
  # Check if boot time is from today
  local boot_date
  boot_date=$(echo "$boot_time" | cut -d' ' -f1)
    if [[ "$boot_date" != "$today" ]]; then
        return 1  # Not booted today
    fi
    
    # Extract hour from boot time
  local boot_hour boot_hour_num
  boot_hour=$(echo "$boot_time" | cut -d' ' -f2 | cut -d':' -f1)
  boot_hour_num=$((10#$boot_hour))
    
    # Check if boot time was between 5AM and 8AM
    if [[ $boot_hour_num -ge 5 ]] && [[ $boot_hour_num -lt 8 ]]; then
        return 0  # Yes, booted in window
    else
        return 1  # No, not booted in window
    fi
}

# Function to show notification/warning
show_startup_warning() {
  local day_name current_time today
  day_name=$(date +%A)
  current_time=$(date +"%H:%M")
  today=$(date +%Y-%m-%d)
    
    echo "⚠️  PC STARTUP TIME WARNING"
    echo "Date: $today ($day_name)"
    echo "Current time: $current_time"
    echo "This PC was expected to be turned on between 5:00 AM and 8:00 AM today, but was not."
    
    # Log the warning
    logger -t pc-startup-monitor "WARNING: PC was not turned on during expected window (5AM-8AM) on $day_name $today"
}

# Main logic
echo "$(date): PC Startup Monitor Check"
logger -t pc-startup-monitor "Running startup time check at $(date)"

# Step 0: Check if today is a monitored day
if ! is_monitored_day; then
    day_name=$(date +%A)
    echo "$(date): Today is $day_name - not a monitored day. Skipping check."
    logger -t pc-startup-monitor "Skipping check - today ($day_name) is not a monitored day"
    exit 0
fi

# Step 1 & 2: Check if current time is between 5AM and 8AM
if is_current_time_in_window; then
    echo "$(date): Current time is within 5AM-8AM window. No action needed."
    logger -t pc-startup-monitor "Current time is within monitored window (5AM-8AM) - no action needed"
    exit 0
fi

# Step 4: Check if PC was turned on between 5AM-8AM today
if was_booted_in_window_today; then
    echo "$(date): PC was booted in expected window (5AM-8AM). All good."
    logger -t pc-startup-monitor "PC was booted in expected window (5AM-8AM) - compliance OK"
else
    echo "$(date): PC was NOT booted in expected window (5AM-8AM). Showing warning."
    show_startup_warning
fi
EOF

  chmod +x "$script_file"
  echo "✓ Created monitoring script: $script_file"
}

# Function to create management script
create_management_script() {
  echo ""
  echo "4. Creating Management Script..."
  echo "=============================="

  local script_file="/usr/local/bin/pc-startup-monitor-manager.sh"

  cat > "$script_file" << 'EOF'
#!/bin/bash
# PC Startup Monitor Manager
# Provides easy management of the PC startup monitoring feature

TIMER_NAME="pc-startup-monitor.timer"
SERVICE_NAME="pc-startup-monitor.service"

show_status() {
    echo "PC Startup Monitor Status"
    echo "========================"
    
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
    echo "Next check scheduled:"
    systemctl list-timers "$TIMER_NAME" --no-pager 2>/dev/null | grep "$TIMER_NAME" || echo "Timer not active"
    
    echo ""
    echo "Recent logs:"
    journalctl -t pc-startup-monitor --no-pager -n 10 2>/dev/null || echo "No recent logs"
}

test_now() {
    echo "Running startup monitor check now..."
    /usr/local/bin/pc-startup-check.sh
}

case "$1" in
    "status")
        show_status
        ;;
    "logs")
        echo "PC Startup Monitor Logs"
        echo "======================"
        journalctl -t pc-startup-monitor --no-pager -n 30
        ;;
    "test")
        test_now
        ;;
    *)
        echo "PC Startup Monitor Manager"
        echo "Usage: $0 {status|logs|test}"
        echo ""
        echo "Commands:"
        echo "  status   - Show current status and next check time"
        echo "  logs     - Show recent monitoring logs"
        echo "  test     - Run a startup check now (for testing)"
        echo ""
        show_status
        ;;
esac
EOF

  chmod +x "$script_file"
  echo "✓ Created management script: $script_file"
}

# Function to enable the services
enable_services() {
  echo ""
  echo "5. Enabling PC Startup Monitor..."
  echo "==============================="

  # Reload systemd daemon
  systemctl daemon-reload
  echo "✓ Reloaded systemd daemon"

  # Enable and start the timer
  systemctl enable pc-startup-monitor.timer
  echo "✓ Enabled pc-startup-monitor timer"

  systemctl start pc-startup-monitor.timer
  echo "✓ Started pc-startup-monitor timer"
}

# Function to test the setup
test_setup() {
  echo ""
  echo "6. Testing Setup..."
  echo "=================="

  echo "Service files:"
  if [[ -f "/etc/systemd/system/pc-startup-monitor.service" ]]; then
    echo "✓ Service file exists"
  else
    echo "✗ Service file missing"
  fi

  if [[ -f "/etc/systemd/system/pc-startup-monitor.timer" ]]; then
    echo "✓ Timer file exists"
  else
    echo "✗ Timer file missing"
  fi

  echo ""
  echo "Timer status:"
  if systemctl is-enabled pc-startup-monitor.timer &> /dev/null; then
    echo "✓ Timer is enabled"
  else
    echo "✗ Timer is not enabled"
  fi

  if systemctl is-active pc-startup-monitor.timer &> /dev/null; then
    echo "✓ Timer is active"
  else
    echo "✗ Timer is not active"
  fi

  echo ""
  echo "Testing current logic:"
  /usr/local/bin/pc-startup-check.sh
}

# Function to show final instructions
show_instructions() {
  echo ""
  echo "=========================================="
  echo "PC Startup Monitor Setup Complete"
  echo "=========================================="
  echo "Summary:"
  echo "✓ Monitoring service created (/etc/systemd/system/pc-startup-monitor.service)"
  echo "✓ Monitoring timer created (/etc/systemd/system/pc-startup-monitor.timer)"
  echo "✓ Monitor script created (/usr/local/bin/pc-startup-check.sh)"
  echo "✓ Management script created (/usr/local/bin/pc-startup-monitor-manager.sh)"
  echo "✓ Timer enabled and started"
  echo ""
  echo "How it works:"
  echo "• Monitors PC startup times on Monday, Friday, Saturday, Sunday"
  echo "• Expects PC to be turned on between 5:00 AM - 8:00 AM"
  echo "• Checks daily at 8:30 AM if PC was turned on in expected window"
  echo "• Shows warning if PC was not turned on during expected time"
  echo ""
  echo "Management commands:"
  echo "  sudo pc-startup-monitor-manager.sh status   - Check status"
  echo "  sudo pc-startup-monitor-manager.sh logs     - View monitor logs"
  echo "  sudo pc-startup-monitor-manager.sh test     - Test monitor now"
  echo ""
  echo "Next check: Tomorrow at 8:30 AM (if it's a monitored day)"
  echo ""
}

# Function to prompt for confirmation
confirm_setup() {
  echo ""
  echo "PC Startup Monitor Setup"
  echo "======================="
  echo "This will set up monitoring for PC startup times."
  echo ""
  echo "Monitoring schedule:"
  echo "- Days: Monday, Friday, Saturday, Sunday"
  echo "- Expected startup time: 5:00 AM - 8:00 AM"
  echo "- Check time: 8:30 AM daily"
  echo "- Action: Show warning if PC wasn't started in expected window"
  echo ""

  if [[ $INTERACTIVE_MODE == "true" ]]; then
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
  else
    echo "Auto-proceeding with setup (use --interactive to prompt)"
    echo "Proceeding with setup..."
    return 0
  fi
}

# Main execution flow
main() {
  # Check for sudo privileges
  check_sudo "$@"

  # Confirm setup
  confirm_setup

  # Create all components
  create_monitoring_service
  create_monitoring_timer
  create_monitoring_script
  create_management_script

  # Enable services
  enable_services

  # Test setup
  test_setup

  # Show instructions
  show_instructions
}

# Run main function
main "$@"
