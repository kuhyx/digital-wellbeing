#!/usr/bin/env python3
"""Focus Mode Daemon - Steam/Browser Mutual Exclusion.

This daemon monitors running processes and enforces mutual exclusion between
Steam (gaming) and web browsers. Whichever starts first "wins" and the other
category is blocked/killed.

Run as a systemd user service for continuous monitoring.
"""

from __future__ import annotations

import argparse
import contextlib
from datetime import datetime, timedelta, timezone
import logging
import signal
import subprocess
import sys
import time
from typing import TYPE_CHECKING

# Sibling module: resolves because Python resolves the symlink used to launch
# this daemon before setting sys.path[0].
from _focus_mode_lib import (
    DEFAULT_WHITELIST_MINUTES,
    POLL_INTERVAL,
    STATE_DIR,
    WHITELIST_FILE,
    get_running_processes,
    is_browser_running,
    is_steam_running,
    kill_browsers,
    kill_steam,
    log,
    notify,
)

if TYPE_CHECKING:
    from types import FrameType

logger = logging.getLogger(__name__)


def is_whitelist_active() -> bool:
    """Check if the browser whitelist is currently active."""
    try:
        if not WHITELIST_FILE.exists():
            return False
        expiry_str = WHITELIST_FILE.read_text().strip()
        expiry = datetime.fromisoformat(expiry_str)
        if datetime.now(tz=timezone.utc) < expiry:
            return True
        # Expired - clean up
        WHITELIST_FILE.unlink(missing_ok=True)
        log("Browser whitelist expired")
        notify(
            "\U0001f6ab Whitelist Expired",
            "Browser whitelist ended. Browsers are blocked again.",
            "normal",
        )
    except (ValueError, OSError) as exc:
        log(f"Error reading whitelist: {exc}")
        with contextlib.suppress(OSError):
            WHITELIST_FILE.unlink(missing_ok=True)
    return False


def activate_whitelist(minutes: int = DEFAULT_WHITELIST_MINUTES) -> None:
    """Activate the browser whitelist for the given number of minutes."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    expiry = datetime.now(tz=timezone.utc) + timedelta(minutes=minutes)
    WHITELIST_FILE.write_text(expiry.isoformat() + "\n")
    expiry_str = expiry.strftime("%H:%M:%S")
    log(f"Browser whitelist activated for {minutes} minutes (expires {expiry_str} UTC)")
    notify(
        "\U0001f513 Browser Whitelist Active",
        f"Browsers allowed for {minutes} minutes (auth/verification).",
        "normal",
    )


def cancel_whitelist() -> None:
    """Cancel the browser whitelist."""
    if WHITELIST_FILE.exists():
        WHITELIST_FILE.unlink(missing_ok=True)
        log("Browser whitelist cancelled")
        notify(
            "\U0001f6ab Whitelist Cancelled",
            "Browser whitelist removed. Browsers are blocked again.",
            "normal",
        )
    else:
        log("No active whitelist to cancel")


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
            log("Both Steam and browsers detected at startup - entering GAMING mode")
            self.current_mode = "gaming"
            self.mode_start_time = datetime.now(tz=timezone.utc)
            kill_browsers()
        elif steam_running:
            self._enter_mode(
                "gaming",
                "Steam detected - entering GAMING mode",
                "\U0001f3ae Gaming Mode|Steam detected. Browsers are now blocked.",
            )
        elif browser_running:
            self._enter_mode(
                "browsing",
                "Browser detected - entering BROWSING mode",
                "\U0001f310 Browsing Mode|Browser detected. Steam is now blocked.",
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
            if is_whitelist_active():
                return
            log("Browser detected during GAMING mode - killing browsers")
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
            log("Steam detected during BROWSING mode - killing Steam")
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
            return f"\U0001f3ae GAMING mode{duration} - browsers blocked"
        return f"\U0001f310 BROWSING mode{duration} - Steam blocked"


def write_status(focus: FocusMode) -> None:
    """Write current status to state file for external queries."""
    with contextlib.suppress(OSError):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        status_file = STATE_DIR / "status"
        with status_file.open("w") as f:
            f.write(focus.get_status() + "\n")
            f.write(f"mode={focus.current_mode or 'none'}\n")
            f.write(f"whitelist={'active' if is_whitelist_active() else 'inactive'}\n")


def _parse_args() -> tuple[str, int]:
    """Parse command-line arguments.

    Returns a (command, minutes) tuple where command is one of
    'daemon', 'whitelist', or 'cancel-whitelist'.
    """
    parser = argparse.ArgumentParser(
        description="Focus Mode Daemon - Steam/Browser mutual exclusion",
    )
    sub = parser.add_subparsers(dest="command")

    wl = sub.add_parser(
        "whitelist",
        help=f"Allow browsers temporarily ({DEFAULT_WHITELIST_MINUTES}m default)",
    )
    wl.add_argument(
        "minutes",
        nargs="?",
        type=int,
        default=DEFAULT_WHITELIST_MINUTES,
        help="Duration in minutes (default: %(default)s)",
    )

    sub.add_parser("cancel-whitelist", help="Cancel active browser whitelist")
    sub.add_parser("status", help="Show whitelist status")

    args = parser.parse_args()
    command = args.command or "daemon"
    minutes = getattr(args, "minutes", DEFAULT_WHITELIST_MINUTES)
    return command, minutes


def _print_whitelist_status() -> None:
    """Print current whitelist status to stdout."""
    if not WHITELIST_FILE.exists():
        return
    try:
        expiry_str = WHITELIST_FILE.read_text().strip()
        expiry = datetime.fromisoformat(expiry_str)
        now = datetime.now(tz=timezone.utc)
        if now < expiry:
            remaining = expiry - now
            int(remaining.total_seconds() // 60)
            int(remaining.total_seconds() % 60)
        else:
            pass
    except (ValueError, OSError):
        pass


def main() -> None:
    """Run the main daemon loop or handle CLI subcommands."""
    logging.basicConfig(format="%(message)s", level=logging.INFO)

    command, minutes = _parse_args()

    if command == "whitelist":
        activate_whitelist(minutes)
        return
    if command == "cancel-whitelist":
        cancel_whitelist()
        return
    if command == "status":
        _print_whitelist_status()
        return

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
