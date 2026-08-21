#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Function to install guard-lib protection (path watcher + enforcement)
# and the bespoke ratchet-aware unlock script.

# Defined in the same file as its use, immediately above it: a definition
# placed in the entry script was stripped by an autoformat pass three times
# during this campaign.
: "${_MS_PAYLOAD_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/payloads" && pwd)}"

create_config_guard() {
	echo ""
	echo "2. Installing Config Guard (guard-lib + unlock script)..."
	echo "=========================================================="

	command -v guardctl >/dev/null 2>&1 || {
		echo "Error: guardctl not found on PATH. Set up ~/guard-lib first (run its install.sh)." >&2
		exit 1
	}

	if guardctl file-guard status "$GUARD_NAME" >/dev/null 2>&1; then
		echo "✓ guard-lib instance '$GUARD_NAME' already installed (content applied above)"
	else
		guardctl file-guard install "$GUARD_NAME" --target "$CONFIG_FILE"
		echo "✓ Installed guard-lib file-guard '$GUARD_NAME' (canonical snapshot, chattr +i, path watcher, initial enforcement)"
	fi

	# Obscure name for unlock script - not documented anywhere
	local unlock_script="/usr/local/sbin/.sd-sched-mgmt"

	# Create unlock script with psychological delay
	# The unlock script is a verbatim payload file, not an inline heredoc:
	# the original heredoc was quoted, so its body was already literal, and
	# inlining it put this lib over the 250-line cap. Same convention as
	# lib/payloads/night-lockdown-*.sh.in. Equivalence is proven by hashing
	# the emitted file, not by inspection.
	cat "$_MS_PAYLOAD_DIR/shutdown-config-unlock.sh.in" >"$unlock_script"

	chmod +x "$unlock_script"
	# Silently create unlock script - do not announce its existence
}
