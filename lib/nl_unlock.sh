#!/usr/bin/env bash
# Helpers sourced by the entry script.


# Where the verbatim payload files live. Defined in the SAME file that uses it,
# and with the use immediately below, because a definition placed further away
# has been stripped by an autoformat pass three times during this work. The
# failure mode is an unbound-variable abort midway through installing the
# lockdown, so it must not depend on a distant line surviving.
: "${_NL_PAYLOAD_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/payloads" && pwd)}"
install_unlock_script() {
	log_info "Installing reversal to $UNLOCK_SCRIPT"
	# The payload is a DATA FILE, not a heredoc: inlining it put this lib over
	# the 250-line cap, and the body is a complete standalone script that is
	# easier to read, lint and diff on its own. The heredoc was quoted
	# (<<'UNLOCK_EOF'), so the body was already literal — copying it verbatim is
	# exactly equivalent. Verified by hashing the emitted result.
	install -m 0755 "$_NL_PAYLOAD_DIR/night-lockdown-unlock.sh.in" "$UNLOCK_SCRIPT"
}
