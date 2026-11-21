#!/bin/bash
# Vendors the kuhy credit from kuhyx/utils at the pinned tag: the terminal
# stack (vendor/kuhy-credit.sh, printed by the CLIs' help and the installers)
# and the M1 logo (vendor/kuhy-credit.svg, shown in README.md).
# kuhy_credit's README forbids hand copies, so bump KUHY_CREDIT_TAG and rerun.
#
# Usage: scripts/vendor_kuhy_credit.sh          # refresh vendor/ from the tag
#        scripts/vendor_kuhy_credit.sh --check  # fail if vendor/ differs (network)

set -euo pipefail

readonly KUHY_CREDIT_TAG="kuhy-credit-v0.3.0"
readonly REPO_URL="https://github.com/kuhyx/utils"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR
# source path at the tag -> vendored path in this repo
readonly -A FILES=(
	["kuhy_credit/terminal/kuhy-credit.sh"]=vendor/kuhy-credit.sh
	["unified-design-system/logo/final/kuhy.svg"]=vendor/kuhy-credit.svg
)

main() {
	local mode="${1:-write}" cache src dst bad=0
	cache="$(mktemp -d)"
	# shellcheck disable=SC2064 # expand now: cache is local
	trap "rm -rf -- '$cache'" EXIT
	# The annotated tag makes clone warn "is not a commit"; show stderr on failure only.
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$KUHY_CREDIT_TAG" \
		"$REPO_URL" "$cache/src" 2>"$cache/clone.err" || { cat "$cache/clone.err" >&2; return 1; }
	for src in "${!FILES[@]}"; do
		dst="$REPO_DIR/${FILES[$src]}"
		if [[ $mode == --check ]]; then
			cmp -s "$cache/src/$src" "$dst" || { echo "differs from $KUHY_CREDIT_TAG: ${FILES[$src]}" >&2; bad=1; }
		else
			install -m 644 "$cache/src/$src" "$dst"
		fi
	done
	return "$bad"
}

main "$@"
