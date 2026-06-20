#!/usr/bin/env bash
# Defense-in-depth network security for Service B and Service C.
#
# Service B (3002) and Service C (3003) already bind to 127.0.0.1 only, which
# is what actually makes them unreachable from outside the VM. This firewall
# is a backstop: if BIND_HOST ever silently changes to 0.0.0.0 (a typo, a
# config drift, a future change someone forgets to scope), this still blocks
# external access instead of quietly exposing two internal services.
#
# Only SSH (22) and HTTP (80, Nginx - the public entry point) are allowed in.
# Everything else is denied by default policy. We also add explicit deny
# rules for 3002/3003 below - redundant with the default policy, but it
# means `ufw status` shows "3002 DENY" / "3003 DENY" directly instead of
# leaving it implicit, which is easier to point at during a review/demo.
#
# Usage:
#   sudo ./scripts/firewall-setup.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script configures ufw and must be run as root. Try: sudo $0" >&2
    exit 1
fi

ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 'Nginx HTTP'
ufw deny 3002
ufw deny 3003
ufw --force enable

echo
echo "Firewall status:"
ufw status verbose
