#!/usr/bin/env bash
# Adds the internal service-discovery entries to /etc/hosts.
# Idempotent: safe to re-run, never adds a duplicate line.
#
# Usage:
#   sudo ./scripts/hosts-setup.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script edits /etc/hosts and must be run as root. Try: sudo $0" >&2
    exit 1
fi

ENTRIES=(
    "127.0.0.1   service-a.internal"
    "127.0.0.1   service-b.internal"
    "127.0.0.1   service-c.internal"
)

for entry in "${ENTRIES[@]}"; do
    if grep -qxF "$entry" /etc/hosts; then
        echo "already present: $entry"
    else
        echo "$entry" >> /etc/hosts
        echo "added:           $entry"
    fi
done

echo
echo "Verifying resolution:"
for name in service-a.internal service-b.internal service-c.internal; do
    getent hosts "$name"
done
