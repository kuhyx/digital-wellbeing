#!/bin/bash
# Browser policy layer for food-block. Sourced by apply.sh (ROOT, DOMAINS).
#
# The policy layer is the primary block: it covers every subdomain and holds
# even when a browser resolves DNS itself. DoH is forced off so the hosts
# layer keeps working too.

# Policy dirs written on every run, installed browser or not, so a browser
# added later is covered before its first launch.
#   chrome            Google Chrome
#   chromium          Chromium, Helium (verified: its binary embeds this path)
#   chromium-browser  Ubuntu's snap Chromium
#   brave             Brave (deb)
#   thorium           Thorium; unverified, the binary scan below confirms it
readonly FB_FIXED_POLICY_DIRS=(
	/etc/opt/chrome/policies
	/etc/chromium/policies
	/etc/chromium-browser/policies
	/etc/brave/policies
	/etc/thorium/policies
	/etc/opt/thorium/policies
)
readonly FB_POLICY_FILE=food_block.json

# Every Chromium fork embeds its policy dir as a string in its main binary.
# Scan large executables (browsers are >50 MB) and collect those paths, so
# forks the fixed list misses (Thorium, Helium builds, new installs) are
# covered automatically on the next tick.
scan_policy_dirs() {
	local roots=() dir
	for dir in /opt /usr/lib /usr/lib64 /usr/bin; do
		[[ -d $ROOT$dir ]] && roots+=("$ROOT$dir")
	done
	((${#roots[@]} > 0)) || return 0
	find "${roots[@]}" -maxdepth 4 -type f -perm /111 -size +50M -print0 2>/dev/null |
		xargs -0 -r grep -aohE '/etc/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*/policies' 2>/dev/null |
		grep -v '\.\.' | sort -u || true
}

policy_dirs() {
	{
		printf '%s\n' "${FB_FIXED_POLICY_DIRS[@]}"
		scan_policy_dirs
	} | awk '!seen[$0]++'
}

render_chromium_policy() {
	jq -n '{
		URLBlocklist: $ARGS.positional,
		DnsOverHttpsMode: "off",
		BuiltInDnsClientEnabled: false,
		TorDisabled: true
	}' --args "${DOMAINS[@]}"
}

apply_chromium_policies() {
	local tmp dir
	tmp="$(mktemp)"
	render_chromium_policy >"$tmp"
	while IFS= read -r dir; do
		write_if_changed "$ROOT$dir/managed/$FB_POLICY_FILE" "$tmp" 1
	done < <(policy_dirs)
	rm -f "$tmp"
	warn_sandboxed_browsers
}

# Snap/Flatpak builds may not see host policy dirs; only /etc/hosts reaches
# them for sure. Say so in the journal instead of claiming coverage.
warn_sandboxed_browsers() {
	local app
	for app in brave thorium helium google-chrome; do
		[[ -d $ROOT/snap/$app ]] && warn "snap $app found: browser policy may not apply"
	done
	for app in com.brave.Browser com.google.Chrome org.chromium.Chromium \
		org.mozilla.firefox; do
		[[ -d $ROOT/var/lib/flatpak/app/$app ]] && warn "flatpak $app found: browser policy may not apply"
	done
	return 0
}

# Firefox (deb and snap) reads /etc/firefox/policies/policies.json. Never
# touch /usr/lib/firefox/distribution: dpkg owns it, +i there breaks apt.
apply_firefox_policy() {
	local ff="$ROOT/etc/firefox/policies/policies.json" base tmp patterns=() d
	for d in "${DOMAINS[@]}"; do
		patterns+=("*://*.$d/*" "*://$d/*")
	done
	base='{}'
	if [[ -s $ff ]]; then
		if jq -e 'type == "object"' "$ff" >/dev/null 2>&1; then
			base="$(cat "$ff")"
		else
			# Firefox ignores an invalid file entirely, which would drop the block.
			warn "invalid $ff replaced"
		fi
	fi
	tmp="$(mktemp)"
	jq '.policies.WebsiteFilter.Block =
			(((.policies.WebsiteFilter.Block // []) + $ARGS.positional) | unique)
		| .policies.DNSOverHTTPS = {Enabled: false, Locked: true}' \
		--args "${patterns[@]}" <<<"$base" >"$tmp"
	write_if_changed "$ff" "$tmp" 1
	rm -f "$tmp"
}
