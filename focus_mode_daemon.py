#!/usr/bin/env python3
"""Focus Mode Daemon - Steam/Browser Mutual Exclusion.

This daemon monitors running processes and enforces mutual exclusion between
Steam (gaming) and web browsers. Whichever starts first "wins" and the other
category is blocked/killed.

Run as a systemd user service for continuous monitoring.
"""

from __future__ import annotations

import contextlib
from datetime import datetime, timezone
import logging
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from types import FrameType

logger = logging.getLogger(__name__)

# Configuration
STATE_DIR = Path.home() / ".local" / "state" / "focus-mode"
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
    timestamp = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"{timestamp} - {message}"
    logger.info("%s", log_line)
    with contextlib.suppress(OSError):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a") as f:
            f.write(log_line + "\n")


def notify(title: str, message: str, urgency: str = "normal") -> None:
    """Send desktop notification."""
    notify_send = shutil.which("notify-send")
    if notify_send is None:
        return
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        subprocess.run(
            [notify_send, "-u", urgency, title, message],
            capture_output=True,
            timeout=5,
            check=False,
        )


def get_running_processes() -> set[str]:
    """Get set of currently running process names."""
    processes: set[str] = set()
    ps_bin = shutil.which("ps")
    if ps_bin is None:
        return processes
    try:
        result = subprocess.run(
            [ps_bin, "-eo", "comm="],
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
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"Error getting processes: {exc}")
    return processes


def is_steam_running(processes: set[str]) -> bool:
    """Check if Steam or any Steam game is running."""
    for proc in processes:
        if proc in STEAM_PATTERNS:
            return True
        if proc.startswith(STEAM_GAME_PREFIX):
            return True
    return False


def is_browser_running(processes: set[str]) -> bool:
    """Check if any browser is running."""
    for proc in processes:
        if proc in ELECTRON_IGNORE:
            continue
        if any(ign in proc for ign in IGNORE_PATTERNS):
            continue
        if proc in BROWSER_PATTERNS:
            return True
    return False


def _run_pkill(pattern: str, *, force: bool = False) -> None:
    """Run pkill with the given pattern."""
    pkill_bin = shutil.which("pkill")
    if pkill_bin is None:
        return
    cmd = [pkill_bin]
    if force:
        cmd.append("-9")
    cmd.extend(["-f", pattern])
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        subprocess.run(cmd, capture_output=True, timeout=5, check=False)


def kill_steam() -> None:
    """Kill all Steam-related processes."""
    log("Killing Steam processes...")
    notify(
        "\U0001f3ae Gaming Blocked",
        "Browser is active. Closing Steam.",
        "critical",
    )

    _run_pkill("steam")
    time.sleep(2)
    _run_pkill("steam", force=True)


def kill_browsers() -> None:
    """Kill all browser processes."""
    log("Killing browser processes...")
    notify(
        "\U0001f310 Browsers Blocked",
        "Steam is active. Closing browsers.",
        "critical",
    )

    for browser in BROWSER_PATTERNS:
        _run_pkill(browser)

    time.sleep(2)

    for browser in BROWSER_PATTERNS:
        _run_pkill(browser, force=True)


class FocusMode:
    """Tracks current focus mode and enforces mutual exclusion."""

    def __init__(self) -> None:
        """Initialize focus mode as inactive."""
        self.current_mode: str | None = None
        self.mode_start_time: datetime | None = None

    def _enter_mode(self, mode: str, msg: str, notification: str) -> None:
        """Enter a new focus mode."""
        log(msg)
        self.current_mode = mode
        self.mode_start_time = datetime.now(tz=timezone.utc)
        notify(*notification.split("|", 1))

    def _handle_no_mode(
        self,
        *,
        steam_running: bool,
        browser_running: bool,
    ) -> None:
        """Handle updates when no mode is active."""
        if steam_running and browser_running:
            log("Both Steam and browsers detected at " "startup - entering GAMING mode")
            self.current_mode = "gaming"
            self.mode_start_time = datetime.now(tz=timezone.utc)
            kill_browsers()
        elif steam_running:
            self._enter_mode(
                "gaming",
                "Steam detected - entering GAMING mode",
                "\U0001f3ae Gaming Mode|" "Steam detected. Browsers are now blocked.",
            )
        elif browser_running:
            self._enter_mode(
                "browsing",
                "Browser detected - entering BROWSING mode",
                "\U0001f310 Browsing Mode|" "Browser detected. Steam is now blocked.",
            )

    def _handle_gaming(
        self,
        *,
        steam_running: bool,
        browser_running: bool,
    ) -> None:
        """Handle updates in gaming mode."""
        if not steam_running:
            log("Steam closed - exiting GAMING mode")
            self.current_mode = None
            self.mode_start_time = None
            notify(
                "\U0001f3ae Gaming Mode Ended",
                "You can now use browsers.",
                "normal",
            )
        elif browser_running:
            log("Browser detected during GAMING mode " "- killing browsers")
            kill_browsers()

    def _handle_browsing(
        self,
        *,
        steam_running: bool,
        browser_running: bool,
    ) -> None:
        """Handle updates in browsing mode."""
        if not browser_running:
            log("Browsers closed - exiting BROWSING mode")
            self.current_mode = None
            self.mode_start_time = None
            notify(
                "\U0001f310 Browsing Mode Ended",
                "You can now use Steam.",
                "normal",
            )
        elif steam_running:
            log("Steam detected during BROWSING mode " "- killing Steam")
            kill_steam()

    def update(self, processes: set[str]) -> None:
        """Update focus mode based on running processes."""
        steam_running = is_steam_running(processes)
        browser_running = is_browser_running(processes)

        if self.current_mode is None:
            self._handle_no_mode(
                steam_running=steam_running,
                browser_running=browser_running,
            )
        elif self.current_mode == "gaming":
            self._handle_gaming(
                steam_running=steam_running,
                browser_running=browser_running,
            )
        elif self.current_mode == "browsing":
            self._handle_browsing(
                steam_running=steam_running,
                browser_running=browser_running,
            )

    def get_status(self) -> str:
        """Get current status string."""
        if self.current_mode is None:
            return "No active focus mode"

        duration = ""
        if self.mode_start_time:
            elapsed = datetime.now(tz=timezone.utc) - self.mode_start_time
            minutes = int(elapsed.total_seconds() // 60)
            duration = f" (active for {minutes}m)"

        if self.current_mode == "gaming":
            return f"\U0001f3ae GAMING mode{duration}" " - browsers blocked"
        return f"\U0001f310 BROWSING mode{duration}" " - Steam blocked"


def write_status(focus: FocusMode) -> None:
    """Write current status to state file for external queries."""
    with contextlib.suppress(OSError):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        status_file = STATE_DIR / "status"
        with status_file.open("w") as f:
            f.write(focus.get_status() + "\n")
            f.write(f"mode={focus.current_mode or 'none'}\n")


def main() -> None:
    """Run the main daemon loop."""
    logging.basicConfig(format="%(message)s", level=logging.INFO)
    log("Focus Mode Daemon starting...")

    def handle_signal(signum: int, _frame: FrameType | None) -> None:
        """Handle termination signals."""
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
        except (
            OSError,
            subprocess.SubprocessError,
        ) as exc:
            log(f"Error in main loop: {exc}")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
