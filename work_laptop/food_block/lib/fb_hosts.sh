#!/bin/bash
# /etc/hosts layer for food-block. Sourced by apply.sh (ROOT, DOMAINS).
#
# Each name maps to 0.0.0.0 AND ::. With an IPv4-only entry, glibc answers
# the AAAA lookup from DNS and the browser connects over IPv6 anyway.
# /etc/hosts is not made immutable: the path unit re-applies on any change.

readonly FB_BEGIN='# >>> food-block (managed by /usr/local/lib/food-block; edits are reverted) >>>'
readonly FB_END='# <<< food-block <<<'

# Hosts cannot wildcard, so add the common subdomain variants of each entry.
hosts_names() {
	local d
	for d in "${DOMAINS[@]}"; do
		printf '%s\nwww.%s\nm.%s\napi.%s\n' "$d" "$d" "$d" "$d"
	done | awk '!seen[$0]++'
}

render_hosts() { # render_hosts <current-hosts> -> stdout
	# Drop any previous block (even a half-deleted one up to EOF), keep the rest.
	awk -v b="$FB_BEGIN" -v e="$FB_END" '
		$0 == b { skip = 1; next }
		$0 == e { skip = 0; next }
		!skip' "$1"
	printf '%s\n' "$FB_BEGIN"
	local name
	while IFS= read -r name; do
		printf '0.0.0.0 %s\n:: %s\n' "$name" "$name"
	done < <(hosts_names)
	printf '%s\n' "$FB_END"
}

apply_hosts() {
	local hosts="$ROOT/etc/hosts" tmp
	[[ -f $hosts ]] || : >"$hosts"
	tmp="$(mktemp)"
	render_hosts "$hosts" >"$tmp"
	write_if_changed "$hosts" "$tmp" 0
	rm -f "$tmp"
}
