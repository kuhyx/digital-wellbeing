#!/bin/bash
# kuhy_credit: prints the one-line "Created by kuhy <url>" credit from the
# vendored kuhy_credit terminal stack (scripts/vendor_kuhy_credit.sh).
# Used by CLI help and installer success output only, never on the
# enforcement path. Silent and exit 0 when the vendored file is absent, so a
# script copied out of the repo never fails over a credit line.

kuhy_credit() {
	local f
	f="$(dirname "${BASH_SOURCE[0]}")/../vendor/kuhy-credit.sh"
	[[ -r $f ]] && bash "$f"
	return 0
}
