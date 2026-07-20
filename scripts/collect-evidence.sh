#!/usr/bin/env bash
# Capture an INSIDE-THE-VM proof transcript: what is listening, firewall state,
# lifecycle status, the end-to-end test, and a single request traced across all
# services by its request_id. Output is timestamped under docs/evidence/ so it
# can be committed as auditable proof (a unit file is not proof until its output
# is captured).
#
# NOTE: the external-exposure and host-forwarding checks must be run from the
#       HOST machine (see docs/evidence/EVIDENCE.md) - they cannot be proven
#       from inside the VM. This script prints a reminder for those.
#
# Usage:
#   ./scripts/collect-evidence.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/docs/evidence"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/evidence-$(date -u +%Y%m%dT%H%M%SZ).txt"

section() { printf '\n==================== %s ====================\n' "$1"; }

{
    echo "Proof transcript (inside VM)"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Host: $(hostname)   Kernel: $(uname -r)"

    section "1. Socket binding (Nginx on :80; A/B/C on 127.0.0.1 only)"
    sudo ss -tulpen | grep -E ':80|:3001|:3002|:3003' || echo "(nothing listening?)"

    section "2. Firewall state (only 22 + 80 inbound; 3002/3003 denied)"
    sudo ufw status verbose

    section "3. Lifecycle (enabled on boot + currently active)"
    systemctl is-enabled service-a service-b service-c
    echo "---"
    systemctl is-active service-a service-b service-c

    section "4. End-to-end smoke test"
    "$REPO_ROOT/scripts/test-end-to-end.sh"

    section "5. Happy-path trace (one request_id across Nginx + A + B + C)"
    RID=$(curl -s http://localhost/service-a/expenses \
        | grep -o '"request_id":"[^"]*"' | cut -d'"' -f4)
    echo "request_id = $RID"
    echo "--- service logs (journald) ---"
    journalctl -u service-a -u service-b -u service-c -o cat --since "1 min ago" \
        | grep "$RID"
    echo "--- nginx access log ---"
    sudo grep "$RID" /var/log/nginx/service-env-access.log

    section "6. Failure behavior (stop B -> A stays up, returns 502 + logs)"
    sudo systemctl stop service-b
    echo "service-a is-active after stopping B: $(systemctl is-active service-a)"
    echo "--- public call while B is down ---"
    curl -s http://localhost/service-a/expenses; echo
    journalctl -u service-a -o cat --since "30 sec ago" | grep request_failed | tail -1
    sudo systemctl start service-b
    echo "(service-b restarted)"

    section "REMINDER: run these from the HOST, not the VM"
    echo "VM IP: $(hostname -I | awk '{print $1}')"
    echo "  curl --connect-timeout 3 http://<VM_IP>/service-a/health   # expect 200"
    echo "  curl --connect-timeout 3 http://<VM_IP>:3002/health        # expect timeout/refused"
    echo "  curl --connect-timeout 3 http://<VM_IP>:3003/health        # expect timeout/refused"
    echo "  curl --connect-timeout 3 http://127.0.0.1:3002/health      # (host) expect fail unless VM forwards it"
} 2>&1 | tee "$OUT"

echo
echo "Saved: $OUT"
echo "Add the host-side outputs (above reminder) to docs/evidence/EVIDENCE.md, then commit."
