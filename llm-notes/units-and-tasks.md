# Systemd units, check-script logic and common tasks

## Systemd Units

### Timer (fires every minute)

```ini
[Timer]
OnCalendar=*:*:00
Persistent=false
AccuracySec=1s
```

### Check Service

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/bin/day-specific-shutdown-check.sh
```

### Path Watcher

```ini
[Path]
PathChanged=/etc/shutdown-schedule.conf
Unit=shutdown-schedule-guard.service
```

## Check Script Logic

```bash
# Pseudocode for day-specific-shutdown-check.sh

source /etc/shutdown-schedule.conf
day=$(date +%u)  # 1=Monday, 7=Sunday
hour=$(date +%H)

if [[ $day -le 3 ]]; then
  shutdown_hour=$MON_WED_HOUR
else
  shutdown_hour=$THU_SUN_HOUR
fi

# Check if in shutdown window
if [[ $hour -ge $shutdown_hour ]] || [[ $hour -lt $MORNING_END_HOUR ]]; then
  systemctl poweroff
fi
```

## Common Tasks

### Check Current Status

```bash
/usr/local/bin/day-specific-shutdown-manager.sh status
# Or run setup script with 'status' argument
```

### Make Schedule Stricter

Edit the constants in `setup_midnight_shutdown.sh`:

```bash
SCHEDULE_MON_WED_HOUR=20  # Changed from 21 to 20 (earlier)
```

Then re-run:

```bash
sudo ./setup_midnight_shutdown.sh
```

### Make Schedule More Lenient (Requires Unlock)

```bash
sudo /usr/local/sbin/unlock-shutdown-schedule
# Wait for delay, edit config, save
```

### Disable Timer (Will Be Re-Enabled!)

```bash
sudo systemctl disable --now day-specific-shutdown.timer
# Monitor service will re-enable it automatically
```

### Check Protection Status

```bash
lsattr /etc/shutdown-schedule.conf
# Should show: ----i--------e--

systemctl status shutdown-schedule-guard.path
systemctl status shutdown-timer-monitor.service
```
