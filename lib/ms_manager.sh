#!/usr/bin/env bash
# Helpers sourced by the entry script: the user-facing management CLI
# (/usr/local/bin/day-specific-shutdown-manager.sh). Split out of
# ms_units.sh to keep both under the 250-line cap.

# Defined in the same file as its use (see ms_config_guard.sh for why).
: "${_MS_PAYLOAD_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/payloads" && pwd)}"

# Function to create management script
create_management_script() {
	echo ""
	echo "5. Creating Management Script..."
	echo "=============================="

	local script_file="/usr/local/bin/day-specific-shutdown-manager.sh"

	# A tracked payload with the installed basename, not a generated heredoc,
	# so the installed copy traces back to this repo by name. The old heredoc
	# was quoted, so the body is byte-identical.
	install -m 0755 "$_MS_PAYLOAD_DIR/day-specific-shutdown-manager.sh" "$script_file"
	echo "✓ Created management script: $script_file"
}
