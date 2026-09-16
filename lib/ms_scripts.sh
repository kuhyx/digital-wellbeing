#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Defined in the same file that uses it, with the use directly below -- see
# lib/nl_enter.sh for why a distant definition is not safe here.
: "${_MS_PAYLOAD_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/payloads" && pwd)}"

# Function to create smart shutdown check script
create_shutdown_check_script() {
	echo ""
	echo "6. Creating Smart Shutdown Check Script..."
	echo "========================================"

	local check_script="/usr/local/bin/day-specific-shutdown-check.sh"

	# The payload is a DATA FILE, not a heredoc, for the same reason the
	# night-lockdown payloads are: the body is a complete standalone script
	# that the tests exercise directly (tests/test_shutdown_check_lift.sh),
	# and a quoted heredoc was already literal, so this is byte-identical.
	install -m 0755 "$_MS_PAYLOAD_DIR/day-specific-shutdown-check.sh.in" "$check_script"

	echo "✓ Created smart shutdown check script: $check_script"
}
