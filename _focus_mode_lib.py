"""Shared pieces of the focus-mode daemon: config, logging, process inspection.

Split out of focus_mode_daemon.py to keep both files within the repo's 500-line
limit. This half is everything the daemon observes or acts on - where state
lives, which processes count as Steam or a browser, how they are read from /proc
and how they are killed. The daemon half owns the policy: whitelist handling and
the mutual-exclusion decisions.

The dependency runs one way (daemon imports lib) so there is no import cycle.
Sibling imports resolve because Python resolves the symlink used to run the
daemon before setting sys.path[0].
"""

from __future__ import annotations

import contextlib
from datetime import datetime, timezone
import logging
from pathlib import Path
import shutil
import subprocess
import time

logger = logging.getLogger(__name__)

# Configuration
STATE_DIR = Path.home() / ".local" / "state" / "focus-mode"
LOG_FILE = STATE_DIR / "focus-mode.log"
WHITELIST_FILE = STATE_DIR / "whitelist"
POLL_INTERVAL = 2  # seconds between process checks
DEFAULT_WHITELIST_MINUTES = 5

# /proc/PID/stat state character for a dead-but-unreaped process.
ZOMBIE_STATE = "Z"

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


def _parse_stat(stat_line: str) -> tuple[str, str] | None:
    """Extract the (name, state) pair from a /proc/PID/stat line.

    The stat format is ``pid (comm) state ...``. The comm field may itself
    contain spaces and ')' characters, so the name is everything between the
    first '(' and the *last* ')' - splitting on whitespace would corrupt any
    process whose name embeds either.

    Args:
        stat_line: Raw contents of a /proc/PID/stat file.

    Returns:
        A (name, state) tuple, or None if the line is malformed.
    """
    open_paren = stat_line.find("(")
    before_close, sep, after_close = stat_line.rpartition(")")
    if open_paren == -1 or not sep:
        return None
    state_fields = after_close.split()
    if not state_fields:
        return None
    return before_close[open_paren + 1 :], state_fields[0]


def get_running_processes() -> set[str]:
    """Get set of currently running process names by reading /proc directly.

    Reads /proc/*/stat rather than /proc/*/comm: both cost one read per PID
    (so the poll loop stays fork-free), but stat also carries the process
    state. That distinction matters because a dead process keeps its name
    until the parent reaps it, so a crashed "steam" lingers as a zombie and
    would otherwise be counted as a running Steam. Zombies are skipped.

    Names are truncated to 15 characters here exactly as they are in
    /proc/*/comm, so the module's process patterns match unchanged.
    """
    processes: set[str] = set()
    try:
        for stat_path in Path("/proc").glob("*/stat"):
            with contextlib.suppress(OSError):
                parsed = _parse_stat(stat_path.read_text())
                if parsed is None:
                    continue
                proc_name, state = parsed
                if state == ZOMBIE_STATE or not proc_name:
                    continue
                processes.add(proc_name.lower())
    except OSError as exc:
        log(f"Error reading /proc: {exc}")
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
