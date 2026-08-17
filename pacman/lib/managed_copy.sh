#!/bin/bash
# Immutable-attribute handling and the guarded copy used for every managed file.
# Sourced by install_pacman_wrapper.sh; inherits the caller's strict mode.
#
# RELock_FILES is a global on purpose: copy_managed_file appends to it and the
# EXIT trap in the entry script drains it. Its capitalization is preserved from
# before the split.

declare -a RELock_FILES=()

is_immutable_file() {
	local file_path="$1"
	[[ -e "$file_path" ]] || return 1
	[[ $(lsattr -d "$file_path" 2>/dev/null | awk '{print $1}') == *i* ]]
}

unlock_immutable_file_if_needed() {
	local file_path="$1"
	if ! command -v chattr >/dev/null 2>&1; then
		return 0
	fi
	if is_immutable_file "$file_path"; then
		chattr -i "$file_path"
		RELock_FILES+=("$file_path")
	fi
}

relock_files_on_exit() {
	if ! command -v chattr >/dev/null 2>&1; then
		return
	fi
	for file_path in "${RELock_FILES[@]}"; do
		[[ -e "$file_path" ]] || continue
		chattr +i "$file_path" 2>/dev/null || true
	done
}

copy_managed_file() {
	local source_file="$1"
	local dest_file="$2"
	local required="$3"
	local label="$4"

	if [[ ! -f "$source_file" ]]; then
		if [[ "$required" == "required" ]]; then
			echo -e "${RED}Error:${NC} Missing required ${label} at ${source_file}" >&2
			exit 1
		fi
		echo -e "${YELLOW}Warning:${NC} Missing ${label} at ${source_file}" >&2
		return
	fi

	unlock_immutable_file_if_needed "$dest_file"
	cp "$source_file" "$dest_file"
}
