#!/bin/bash
# Deployed as /usr/local/bin/nmap. nmap is nonfree (NPSL) and removed from this
# machine; the pacman wrapper refuses to reinstall it. Point the caller at
# rustscan instead. No flag translation, and deliberately NOT an exec of
# rustscan: rustscan's default scripting calls nmap, which would recurse.
set -euo pipefail

cat >&2 <<'EOF'
nmap is blocked (nonfree NPSL licence). Use rustscan:
  rustscan -a <target> -p <ports> -g
  e.g. open SSH hosts on a LAN: rustscan -a 192.168.1.0/24 -p 22 -g
EOF
exit 1
