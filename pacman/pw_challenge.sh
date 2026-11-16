#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Refusal shown when a transaction names nmap (see check_for_nmap). Plain text:
# only ever printed to a terminal.
function refuse_nmap_install() {
	echo -e "${RED}nmap is blocked (nonfree NPSL licence). Use rustscan instead:${NC}" >&2
	echo -e "${CYAN}  rustscan -a <target> -p <ports> -g${NC}" >&2
	return 1
}
