#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Defined in the same file as its use (see ms_config_guard.sh for why).
: "${_MS_PAYLOAD_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/payloads" && pwd)}"

# Function to create the time-boxed override manager (event exceptions like
# watching a live match that runs past the normal shutdown window). Overrides
# are absolute-epoch-bound so they expire on their own; the friction (typed
# confirmation + delay) lives entirely in this CLI, matching the existing
# unlock script's philosophy for the permanent schedule ratchet.
create_override_manager_script() {
	echo ""
	echo "9. Creating Shutdown Override Manager..."
	echo "========================================"

	local overrides_file="/etc/shutdown-schedule-overrides.conf"
	local log_file="/var/log/shutdown-schedule-overrides.log"
	local manager_script="/usr/local/bin/shutdown-override-manager.sh"

	touch "$overrides_file"
	# World-readable (like shutdown-schedule.conf): the i3blocks countdown
	# script runs as the regular user and needs to read active overrides to
	# display them. Only root can write to it (via this manager script).
	chmod 644 "$overrides_file"
	touch "$log_file"
	chmod 600 "$log_file"

	# A tracked payload with the installed basename, not a generated heredoc,
	# so the installed copy traces back to this repo by name. The old heredoc
	# was quoted, so the body is byte-identical.
	install -m 0755 "$_MS_PAYLOAD_DIR/shutdown-override-manager.sh" "$manager_script"
	echo "✓ Created override manager: $manager_script"
	echo "✓ Overrides file: $overrides_file (root-only)"
	echo "✓ Override log: $log_file"
}
