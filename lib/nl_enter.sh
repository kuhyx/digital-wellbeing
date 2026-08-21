#!/usr/bin/env bash
# Helpers sourced by the entry script.

install_enter_script() {
	log_info "Installing lock action to $ENTER_SCRIPT"
	# The payload is a DATA FILE, not a heredoc: inlining it put this lib over
	# the 250-line cap, and the body is a complete standalone script that is
	# easier to read, lint and diff on its own. The heredoc was quoted
	# (<<'ENTER_EOF'), so the body was already literal — copying it verbatim is
	# exactly equivalent. Verified by hashing the emitted result.
	install -m 0755 "$_NL_PAYLOAD_DIR/night-lockdown-enter.sh.in" "$ENTER_SCRIPT"
}
