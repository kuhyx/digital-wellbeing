#!/bin/bash
# Policy integrity file (chattr +i) and the deployment drift manifest.
# Sourced by install_pacman_wrapper.sh; inherits the caller's strict mode.
#
# test_pacman_wrapper_security.sh greps THIS file's source text for the literal
# `sha256sum "$LOCK_LIB_DEST"` -- it asserts the stale-lock library is covered
# by the integrity manifest. Keep that line verbatim.

# Writes $INTEGRITY_FILE and makes it immutable. Exits non-zero if any policy
# file is missing, because a partial integrity file is worse than none.
write_policy_integrity_file() {
	# Create integrity directory if it doesn't exist
	mkdir -p "$INTEGRITY_DIR"
	chmod 755 "$INTEGRITY_DIR"

	# Generate checksums of policy files for integrity verification
	echo -e "${BLUE}Generating integrity checksums for policy files...${NC}"
	unlock_immutable_file_if_needed "$INTEGRITY_FILE"

	# Ensure all critical policy files exist before checksumming
	missing_files=()
	[[ ! -f "$BLOCKED_DEST" ]] && missing_files+=("$BLOCKED_DEST")
	[[ ! -f "$GREYLIST_DEST" ]] && missing_files+=("$GREYLIST_DEST")
	[[ ! -f "$LOCK_LIB_DEST" ]] && missing_files+=("$LOCK_LIB_DEST")

	if [[ ${#missing_files[@]} -gt 0 ]]; then
		echo -e "${RED}Error: Critical policy files are missing:${NC}"
		printf '%s\n' "${missing_files[@]}" >&2
		echo -e "${RED}Installation incomplete. Cannot create integrity file.${NC}"
		exit 1
	fi

	{
		sha256sum "$BLOCKED_DEST" || {
			echo -e "${RED}Failed to checksum blocked list${NC}" >&2
			exit 1
		}
		sha256sum "$GREYLIST_DEST" || {
			echo -e "${RED}Failed to checksum greylist${NC}" >&2
			exit 1
		}
		# The shared stale-lock library is executed (sourced) by the wrapper, so it is
		# integrity-checked too: pacman_wrapper.sh sources it only AFTER
		# verify_policy_integrity passes, so a tampered lib is rejected before it runs.
		sha256sum "$LOCK_LIB_DEST" || {
			echo -e "${RED}Failed to checksum lock library${NC}" >&2
			exit 1
		}
		# Whitelist is optional
		if [[ -f "$WHITELIST_DEST" ]]; then
			sha256sum "$WHITELIST_DEST" || {
				echo -e "${RED}Failed to checksum whitelist${NC}" >&2
				exit 1
			}
		fi
	} >"$INTEGRITY_FILE"

	# Verify integrity file was created and has content
	if [[ ! -s "$INTEGRITY_FILE" ]]; then
		echo -e "${RED}Error: Integrity file was not created or is empty${NC}"
		exit 1
	fi

	# Make integrity file immutable
	chmod 400 "$INTEGRITY_FILE"
	if command -v chattr >/dev/null 2>&1; then
		chattr +i "$INTEGRITY_FILE" 2>/dev/null || echo -e "${YELLOW}Warning: Could not make integrity file immutable${NC}"
	fi
}

# Record a drift manifest: the hash of every SOURCE file we installed from, and
# of the installed copies we produced. check_and_enable_services.sh replays it
# with `sha256sum -c`, which answers both questions in one command:
#   - a source line fails => the repo moved on, this deployment is stale
#   - a dest line fails   => someone edited the installed copy directly
# Neither was detectable before: the checker only tested that files EXIST, which
# is why a wrapper 7.6 KB behind the repo (no integrity manifest, no
# pacman_lock_lib, no guard-lib fallbacks) ran unnoticed for a week while the
# hourly maintenance timer kept reporting "ok".
# Deliberately NOT chattr +i (unlike the policy integrity file above): this is a
# drift record, not a security boundary, and it must be rewritable each install.
write_drift_manifest() {
	echo -e "${BLUE}Recording deployment drift manifest...${NC}"
	# ABSOLUTE paths only. The SOURCE_* vars are built from `dirname "$0"`, so
	# they are relative whenever the installer is invoked by a relative path — and
	# check_and_enable_services.sh replays this manifest from systemd with cwd=/,
	# where relative entries resolve to nothing. sha256sum -c would report those as
	# failures, the checker would read that as drift, and it would reinstall on
	# every single hourly run forever.
	manifest_sources=()
	for src in "$WRAPPER_SOURCE" "$LOCK_LIB_SOURCE" "$BLOCKED_SOURCE" "$GREYLIST_SOURCE" \
		"$MAKEPKG_CAPPED_SOURCE" "$MKPKG_SOURCE" "$WHITELIST_SOURCE"; do
		[[ -f "$src" ]] || continue # whitelist is optional
		manifest_sources+=("$(readlink -f "$src")")
	done

	{
		sha256sum "${manifest_sources[@]}" || {
			echo -e "${RED}Failed to checksum wrapper sources${NC}" >&2
			exit 1
		}
		sha256sum "$LOCK_LIB_DEST" || {
			echo -e "${RED}Failed to checksum installed lock lib${NC}" >&2
			exit 1
		}
	} >"$SOURCE_MANIFEST"

	if [[ ! -s "$SOURCE_MANIFEST" ]]; then
		echo -e "${RED}Error: drift manifest was not created or is empty${NC}" >&2
		exit 1
	fi
	chmod 644 "$SOURCE_MANIFEST"
}
