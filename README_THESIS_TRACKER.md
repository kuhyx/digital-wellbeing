# Bachelor/Master's Thesis Work Tracker

A comprehensive system to help you stay focused on your thesis by blocking distractions until you've put in your work hours.

> **Note**: This tracker was originally requested for a bachelor thesis, but works equally well for master's thesis work. The default repository name `praca_magisterska` is Polish for "master's thesis" - you can customize this during installation.

## Overview

This system monitors your active windows and tracks time spent on thesis-related work. Steam and other distracting websites are blocked until you accumulate the required work time. It's designed to be as hard to circumvent as possible while remaining fair and transparent.

## How It Works

1. **Work Tracking**: The system monitors your active window every 5 seconds
2. **Time Accumulation**: When you're working on approved thesis applications, time accumulates
3. **Unlocking**: After reaching the work quota (default: 2 hours), distractions are unblocked
4. **Decay System**: Using Steam or distractions decays your work time (default: 30 minutes per hour)
5. **Re-blocking**: When work time falls below quota, distractions are blocked again

## Tracked Applications

The following applications count as "thesis work":

### Game Engines

- **Unreal Engine** (all versions: UE4, UE5, UnrealEditor)
- **Unity Engine** (Unity Editor and Unity Hub)
- **Nvidia Omniverse** (Omniverse and Kit)

### Development Tools

- **Visual Studio Code** - **ONLY** when working on the `praca_magisterska` repository
  - The window title must contain the repository name
  - Or the workspace must have the repository open

## Blocked Sites

When you haven't met your work quota, the following are blocked via `/etc/hosts`:

### Gaming

- All Steam domains (steampowered.com, steamcommunity.com, etc.)

### Social Media

- Reddit
- Twitter/X
- Facebook
- Instagram

### Video/Entertainment

- YouTube
- Twitch
- 9gag
- Imgur

## Installation

### Quick Start

```bash
# Clone or navigate to the repository
cd /path/to/scripts

# Run the installer (will prompt for sudo)
sudo scripts/digital_wellbeing/setup_thesis_work_tracker.sh
```

### Custom Configuration

```bash
# Set custom work quota (e.g., 3 hours)
sudo scripts/digital_wellbeing/setup_thesis_work_tracker.sh --work-quota 180

# Set custom decay rate (e.g., 20 minutes per hour)
sudo scripts/digital_wellbeing/setup_thesis_work_tracker.sh --decay-rate 20

# Set custom VS Code repository name
sudo scripts/digital_wellbeing/setup_thesis_work_tracker.sh --vscode-repo "my-thesis-repo"

# Combine multiple options
sudo scripts/digital_wellbeing/setup_thesis_work_tracker.sh \
    --work-quota 150 \
    --decay-rate 25 \
    --vscode-repo "bachelor-thesis"
```

### Prerequisites

The installer will check for required dependencies:

- `xdotool` - for window detection
- `systemd` - for service management

On Arch Linux:

```bash
sudo pacman -S xdotool
```

On Ubuntu/Debian:

```bash
sudo apt install xdotool
```

## Usage

### After Installation

The system runs automatically as a systemd service. Just start working on your thesis!

### Checking Your Progress

```bash
# View current status
systemctl status thesis-work-tracker@$USER.service

# View live logs
tail -f /var/log/thesis-work-tracker/tracker.log

# Check your accumulated work time
sudo cat /var/lib/thesis-work-tracker/work-time.state
```

### Understanding the State File

The state file shows:

- `TOTAL_WORK_SECONDS`: Your accumulated work time (in seconds)
- `STEAM_ACCESS_GRANTED`: Whether distractions are currently unblocked (1=yes, 0=no)
- `CURRENT_SESSION_SECONDS`: Time in your current work session
- `LAST_WORK_SESSION_START`: When your current session started

### Managing the Service

```bash
# Restart the service
sudo systemctl restart thesis-work-tracker@$USER.service

# Stop the service temporarily
sudo systemctl stop thesis-work-tracker@$USER.service

# Start the service
sudo systemctl start thesis-work-tracker@$USER.service

# Disable auto-start
sudo systemctl disable thesis-work-tracker@$USER.service

# Re-enable auto-start
sudo systemctl enable thesis-work-tracker@$USER.service
```

## Uninstallation

```bash
sudo scripts/digital_wellbeing/setup_thesis_work_tracker.sh --uninstall
```

**Note**: This preserves your state file and logs. To completely remove everything:

```bash
# Remove state directory
sudo chattr -i -R /var/lib/thesis-work-tracker
sudo rm -rf /var/lib/thesis-work-tracker

# Remove logs
sudo rm -rf /var/log/thesis-work-tracker
```

## Security & Anti-Circumvention Features

This system is designed to be difficult to bypass:

### 1. **Immutable State Files**

- State files are protected with `chattr +i` (immutable flag)
- Cannot be edited even by root without removing the flag first
- Automatically re-applied after each update

### 2. **Auto-Restart Service**

- Systemd service automatically restarts if killed
- Runs continuously in the background
- Starts automatically on boot

### 3. **Hosts File Integration**

- Integrates with the repository's hosts guard system
- Uses immutable `/etc/hosts` file
- Cannot be easily bypassed by changing DNS

### 4. **Process Integrity**

- Monitors actual active windows, not just running processes
- Detects if you switch away from work applications
- VS Code requires specific repository to be open

### 5. **Decay Mechanism**

- Using Steam/distractions consumes your earned work time
- Forces sustained work habits, not just one-time work sessions
- Fair: 30 minutes of decay per hour of distraction usage

### 6. **Locked Configuration**

- Configuration is embedded in the installed script
- Cannot be easily modified without reinstalling
- Protected script location in `/usr/local/bin`

## Troubleshooting

### Service Not Starting

```bash
# Check service status
systemctl status thesis-work-tracker@$USER.service

# Check for errors
journalctl -u thesis-work-tracker@$USER.service -n 50

# Verify dependencies
which xdotool
which systemctl
```

### Window Detection Not Working

The tracker requires X11 and `xdotool`. Check:

```bash
# Verify X11 is running
echo $DISPLAY

# Test xdotool
xdotool getactivewindow getwindowname

# Check XAUTHORITY
echo $XAUTHORITY
ls -la ~/.Xauthority
```

### VS Code Repository Not Detected

Make sure:

1. The window title shows the repository name
2. You're working in the correct repository folder
3. The repository name matches what you specified during installation

Test with:

```bash
xdotool getactivewindow getwindowname
# Should show something like: "praca_magisterska - Visual Studio Code"
```

### Hosts File Not Updating

Check:

```bash
# View current hosts file
sudo cat /etc/hosts | grep steam

# Check immutable flag
lsattr /etc/hosts

# Service logs
tail -f /var/log/thesis-work-tracker/tracker.log
```

## Configuration Files

- **Tracker Script**: `/usr/local/bin/thesis_work_tracker.sh`
- **Systemd Service**: `/etc/systemd/system/thesis-work-tracker@.service`
- **State File**: `/var/lib/thesis-work-tracker/work-time.state`
- **Log File**: `/var/log/thesis-work-tracker/tracker.log`

## Tips for Success

1. **Start Early**: Begin your work sessions in the morning when you're fresh
2. **Take Breaks**: The system only tracks active window time, so take regular breaks
3. **Focus Sessions**: Work in focused 2-hour blocks to unlock entertainment
4. **Monitor Progress**: Check your logs regularly to see your work patterns
5. **Be Honest**: The system trusts you're actually working when applications are open

## FAQ

### Can I bypass this system?

Technically yes, but it's designed to make bypassing more effort than just doing the work:

- You'd need to disable the service (but it auto-restarts)
- You'd need to modify immutable files (requires chattr commands)
- You'd need to fake window activity (complex)
- You'd need to edit protected state files (also complex)

The point isn't to make it impossible, but to add enough friction that doing your thesis work is easier.

### What if I need to use VS Code for something else?

VS Code only counts as work when you're in the `praca_magisterska` repository. Other projects won't count toward your thesis time.

### Can I adjust the work quota after installation?

Yes, but you need to:

1. Uninstall the current system
2. Reinstall with new parameters
3. Your accumulated time is preserved in the state file

### Does this work on Wayland?

Currently, this requires X11 for `xdotool` window detection. Wayland support would require adapting to use different tools like `wlrctl` or `swaymsg`.

### What happens if I reboot?

The service starts automatically on boot, and your accumulated work time is preserved in the state file.

## License

This is part of the kuhyx/scripts repository. Use at your own risk and discretion.

## Contributing

Found a bug or have a suggestion? Please open an issue in the main repository.

## Acknowledgments

This tool is built on top of the digital wellbeing framework in this repository, including:

- Hosts guard system
- Psychological friction mechanisms
- Systemd service patterns

Good luck with your bachelor thesis! 🎓
