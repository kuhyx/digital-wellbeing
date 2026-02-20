#!/usr/bin/env python3
"""Focus Mode Daemon - Steam/Browser Mutual Exclusion

This daemon monitors running processes and enforces mutual exclusion between
Steam (gaming) and web browsers. Whichever starts first "wins" and the other
category is blocked/killed.

Run as a systemd user service for continuous monitoring.
"""

from datetime import datetime
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

# Configuration
STATE_DIR = (
    Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "focus-mode"
)
LOG_FILE = STATE_DIR / "focus-mode.log"
POLL_INTERVAL = 2  # seconds between process checks

# Process patterns
STEAM_PATTERNS = frozenset(
    [
        "steam",
        "steamwebhelper",
        "steam_ocompati",  # Proton compatibility tool
    ]
)

# Games often have steam_app_ prefix in process name
STEAM_GAME_PREFIX = "steam_app_"

BROWSER_PATTERNS = frozenset(
    [
        "firefox",
        "firefox-esr",
        "librewolf",
        "chromium",
        "chrome",
        "google-chrome",
        "brave",
        "vivaldi",
        "opera",
        "microsoft-edge",
        "ungoogled-chromium",
        "thorium",
    ]
)

# Electron apps that should NOT be treated as browsers
# These use Chromium under the hood but are not web browsers
ELECTRON_IGNORE = frozenset(
    [
        "electron",
        "code",  # VS Code
        "chrome_crashpad",  # Crashpad handler used by all Electron apps
    ]
)

# Patterns to ignore (browser helpers that aren't the main browser)
IGNORE_PATTERNS = frozenset(
    [
        "crashhandler",
        "update",
        "helper",
        "crashpad",
    ]
)


def log(message: str) -> None:
    """Log message with timestamp."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"{timestamp} - {message}"
    print(log_line)
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(log_line + "\n")
    except Exception:
        pass


def notify(title: str, message: str, urgency: str = "normal") -> None:
    """Send desktop notification."""
    try:
        subprocess.run(
            ["notify-send", "-u", urgency, title, message],
            capture_output=True,
            timeout=5,
            check=False,
        )
    except Exception:
        pass


def get_running_processes() -> set[str]:
    """Get set of currently running process names."""
    processes = set()
    try:
        result = subprocess.run(
            ["ps", "-eo", "comm="],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if result.returncode == 0:
            for line in result.stdout.strip().split("\n"):
                proc_name = line.strip().lower()
                if proc_name:
                    processes.add(proc_name)
    except Exception as e:
        log(f"Error getting processes: {e}")
    return processes


def is_steam_running(processes: set[str]) -> bool:
    """Check if Steam or any Steam game is running."""
    for proc in processes:
        # Check for Steam main processes
        if proc in STEAM_PATTERNS:
            return True
        # Check for Steam games (have steam_app_ prefix)
        if proc.startswith(STEAM_GAME_PREFIX):
            return True
    return False


def is_browser_running(processes: set[str]) -> bool:
    """Check if any browser is running."""
    for proc in processes:
        # Skip Electron apps and ignored patterns
        if proc in ELECTRON_IGNORE:
            continue
        if any(ign in proc for ign in IGNORE_PATTERNS):
            continue
        # Use exact match to avoid false positives from Electron apps
        if proc in BROWSER_PATTERNS:
            return True
    return False


def kill_steam() -> None:
    """Kill all Steam-related processes."""
    log("Killing Steam processes...")
    notify("🎮 Gaming Blocked", "Browser is active. Closing Steam.", "critical")

    try:
        # First try graceful shutdown
        subprocess.run(
            ["pkill", "-f", "steam"], capture_output=True, timeout=5, check=False
        )
        time.sleep(2)

        # Force kill if still running
        subprocess.run(
            ["pkill", "-9", "-f", "steam"], capture_output=True, timeout=5, check=False
        )
    except Exception as e:
        log(f"Error killing Steam: {e}")


def kill_browsers() -> None:
    """Kill all browser processes."""
    log("Killing browser processes...")
    notify("🌐 Browsers Blocked", "Steam is active. Closing browsers.", "critical")

    for browser in BROWSER_PATTERNS:
        try:
            subprocess.run(
                ["pkill", "-f", browser], capture_output=True, timeout=5, check=False
            )
        except Exception:
            pass

    time.sleep(2)

    # Force kill if still running
    for browser in BROWSER_PATTERNS:
        try:
            subprocess.run(
                ["pkill", "-9", "-f", browser],
                capture_output=True,
                timeout=5,
                check=False,
            )
        except Exception:
            pass


class FocusMode:
    """Tracks current focus mode and enforces mutual exclusion."""

    def __init__(self):
        self.current_mode: str | None = None  # "gaming" or "browsing" or None
        self.mode_start_time: datetime | None = None

    def update(self, processes: set[str]) -> None:
        """Update focus mode based on running processes."""
        steam_running = is_steam_running(processes)
        browser_running = is_browser_running(processes)

        if self.current_mode is None:
            # No mode set yet - first to start wins
            if steam_running and browser_running:
                # Both running at startup - prefer gaming mode (close browsers)
                log(
                    "Both Steam and browsers detected at startup - entering GAMING mode"
                )
                self.current_mode = "gaming"
                self.mode_start_time = datetime.now()
                kill_browsers()
            elif steam_running:
                log("Steam detected - entering GAMING mode")
                self.current_mode = "gaming"
                self.mode_start_time = datetime.now()
                notify(
                    "🎮 Gaming Mode",
                    "Steam detected. Browsers are now blocked.",
                    "normal",
                )
            elif browser_running:
                log("Browser detected - entering BROWSING mode")
                self.current_mode = "browsing"
                self.mode_start_time = datetime.now()
                notify(
                    "🌐 Browsing Mode",
                    "Browser detected. Steam is now blocked.",
                    "normal",
                )

        elif self.current_mode == "gaming":
            if not steam_running:
                # Steam closed - exit gaming mode
                log("Steam closed - exiting GAMING mode")
                self.current_mode = None
                self.mode_start_time = None
                notify("🎮 Gaming Mode Ended", "You can now use browsers.", "normal")
            elif browser_running:
                # Browser started while in gaming mode - kill it
                log("Browser detected during GAMING mode - killing browsers")
                kill_browsers()

        elif self.current_mode == "browsing":
            if not browser_running:
                # Browsers closed - exit browsing mode
                log("Browsers closed - exiting BROWSING mode")
                self.current_mode = None
                self.mode_start_time = None
                notify("🌐 Browsing Mode Ended", "You can now use Steam.", "normal")
            elif steam_running:
                # Steam started while in browsing mode - kill it
                log("Steam detected during BROWSING mode - killing Steam")
                kill_steam()

    def get_status(self) -> str:
        """Get current status string."""
        if self.current_mode is None:
            return "No active focus mode"

        duration = ""
        if self.mode_start_time:
            elapsed = datetime.now() - self.mode_start_time
            minutes = int(elapsed.total_seconds() // 60)
            duration = f" (active for {minutes}m)"

        if self.current_mode == "gaming":
            return f"🎮 GAMING mode{duration} - browsers blocked"
        return f"🌐 BROWSING mode{duration} - Steam blocked"


def write_status(focus: FocusMode) -> None:
    """Write current status to state file for external queries."""
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        status_file = STATE_DIR / "status"
        with open(status_file, "w") as f:
            f.write(focus.get_status() + "\n")
            f.write(f"mode={focus.current_mode or 'none'}\n")
    except Exception:
        pass


def main():
    """Main daemon loop."""
    log("Focus Mode Daemon starting...")

    # Setup signal handlers
    def handle_signal(signum, frame):
        log(f"Received signal {signum} - shutting down")
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    focus = FocusMode()

    while True:
        try:
            processes = get_running_processes()
            focus.update(processes)
            write_status(focus)
        except Exception as e:
            log(f"Error in main loop: {e}")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
