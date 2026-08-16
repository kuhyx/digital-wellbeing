# Known vulnerabilities, troubleshooting and hard stops

## KNOWN VULNERABILITIES

1. **Information Disclosure**: Error messages tell user exactly how to bypass
2. **Unlock Script Discoverable**: Path mentioned in error messages
3. **Timer Monitor Killable**: User can stop the monitor then the timer
4. **Check Script Unprotected**: `/usr/local/bin/day-specific-shutdown-check.sh` can be edited

**TODO**:

- Remove helpful bypass instructions from error messages
- Rename unlock script to obscure name
- Protect check script with integrity verification

## Troubleshooting

### Timer not firing

```bash
systemctl status day-specific-shutdown.timer
systemctl list-timers | grep shutdown
```

### Config not being enforced

```bash
# Check path watcher
systemctl status shutdown-schedule-guard.path

# Manually trigger enforcement
sudo /usr/local/sbin/enforce-shutdown-schedule.sh
```

### Wrong time shown in i3blocks

```bash
# Verify config
cat /etc/shutdown-schedule.conf

# Check i3blocks config
cat ~/.config/i3blocks/config | grep shutdown
```

## DO NOT

1. ❌ Edit setup script constants to make schedule later (will be blocked)
2. ❌ Delete canonical config (breaks restoration)
3. ❌ Stop `shutdown-timer-monitor.service` (timer will be re-enabled anyway)
4. ❌ Modify check script to skip shutdown (defeats purpose)
5. ❌ Lower `MORNING_END_HOUR` (always blocked, shortens shutdown window)
