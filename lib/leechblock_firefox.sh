#!/usr/bin/env bash
# Firefox enterprise-policy installation for install_leechblock.sh.
# Sourced by the installer; inherits its strict mode and info/warn helpers.
# Reads AUTO_FIREFOX; writes policies.json under system paths.
#
# Whether a Firefox-family browser was detected arrives as $1 rather than as
# the ff_found global the pre-split code used: that global is written in
# leechblock_browsers.sh, and reading it here would be a cross-file global the
# linter genuinely cannot resolve (it runs without -x), i.e. a real SC2154
# rather than noise. Suppressions are forbidden, so the value is passed
# explicitly instead.
install_firefox_policy() {
	local ff_found="${1:-0}"

	# If requested, attempt automatic install on Firefox via enterprise policies
	if [[ $AUTO_FIREFOX -eq 1 && $ff_found -eq 1 ]]; then
		echo
		info "Attempting Firefox auto-install via Enterprise Policies (requires sudo)."
		# AMO info
		ADDON_ID="leechblockng@proginosko.com"
		ADDON_AMO_URL="https://addons.mozilla.org/firefox/downloads/latest/leechblock-ng/latest.xpi"

		# Determine policy directories for detected Firefox-like browsers
		declare -a POLICY_DIRS
		POLICY_DIRS=()
		if command -v firefox >/dev/null 2>&1; then
			POLICY_DIRS+=("/etc/firefox/policies" "/usr/lib/firefox/distribution")
		fi
		if command -v firefox-developer-edition >/dev/null 2>&1; then
			POLICY_DIRS+=("/etc/firefox-developer-edition/policies" "/usr/lib/firefox-developer-edition/distribution")
		fi
		if command -v librewolf >/dev/null 2>&1; then
			POLICY_DIRS+=("/etc/librewolf/policies" "/usr/lib/librewolf/distribution")
		fi
		# Generic mozilla path as fallback
		POLICY_DIRS+=("/usr/lib/mozilla/distribution")

		updated_any=0
		for pol_target in "${POLICY_DIRS[@]}"; do
			tmp_pol=$(mktemp)
			existing="${pol_target}/policies.json"
			if sudo test -f "$existing"; then
				info "Merging into existing policies.json at $existing"
				sudo cp "$existing" "$tmp_pol"
				if command -v jq >/dev/null 2>&1; then
					merged=$(jq --arg id "$ADDON_ID" --arg url "$ADDON_AMO_URL" '
          .policies |= (. // {}) |
          .policies.ExtensionSettings |= (. // {}) |
          .policies.ExtensionSettings."*" |= (. // {"installation_mode":"allowed"}) |
          .policies.ExtensionSettings[$id] |= (. // {}) |
          .policies.ExtensionSettings[$id].installation_mode = "force_installed" |
          .policies.ExtensionSettings[$id].install_url = $url
        ' "$tmp_pol") || merged=""
					if [[ -n $merged ]]; then
						printf '%s\n' "$merged" >"$tmp_pol"
					else
						warn "jq merge failed; skipping $pol_target"
						rm -f "$tmp_pol"
						continue
					fi
				else
					warn "jq not available; creating minimal policies.json (existing file will be backed up)."
					sudo cp "$existing" "${existing}.bak.$(date +%s)"
					cat >"$tmp_pol" <<JSON
{
  "policies": {
    "ExtensionSettings": {
      "*": { "installation_mode": "allowed" },
      "$ADDON_ID": {
        "installation_mode": "force_installed",
        "install_url": "$ADDON_AMO_URL"
      }
    }
  }
}
JSON
				fi
			else
				info "Creating new policies.json at $pol_target"
				cat >"$tmp_pol" <<JSON
{
  "policies": {
    "ExtensionSettings": {
      "*": { "installation_mode": "allowed" },
      "$ADDON_ID": {
        "installation_mode": "force_installed",
        "install_url": "$ADDON_AMO_URL"
      }
    }
  }
}
JSON
			fi

			sudo mkdir -p "$pol_target"
			sudo cp "$tmp_pol" "$pol_target/policies.json"
			rm -f "$tmp_pol"
			updated_any=1
		done

		if [[ $updated_any -eq 1 ]]; then
			info "Firefox policies updated. Restart Firefox/LibreWolf to complete installation of LeechBlock NG."
		else
			warn "No Firefox policy locations updated. You may not have a supported Firefox installed."
		fi
		info "Firefox policy updated. Restart Firefox to complete installation of LeechBlock NG."
	fi
}
