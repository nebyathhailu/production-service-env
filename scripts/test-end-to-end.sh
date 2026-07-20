#!/usr/bin/env bash
# Quick end-to-end sanity check for the whole stack: Nginx -> Service A ->
# Service B -> Service C -> Service A callback, plus the network-security
# boundary (B not reachable through Nginx). Run after deploying, after a
# reboot, or any time you want a fast "is everything actually working" check.
#
# Usage:
#   ./scripts/test-end-to-end.sh

set -uo pipefail

PASS=0
FAIL=0

check() {
    local description="$1"
    local result="$2"
    if [[ "$result" == "0" ]]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description"
        FAIL=$((FAIL + 1))
    fi
}

# 1. Service A health, through Nginx.
curl -s http://localhost/service-a/health | grep -q '"status":"healthy"'
check "Service A health check (through Nginx)" "$?"

# 2. Full request flow: Nginx -> expense-api -> policy -> approval -> callback.
curl -s http://localhost/service-a/expenses | grep -q '"status":"approved"'
check "Full expense flow (expense-api -> policy -> approval -> callback)" "$?"

# 3. Service B must NOT be reachable through Nginx.
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/service-b)
[[ "$code" == "404" ]]
check "Service B not routable through Nginx (got HTTP $code, want 404)" "$?"

# 4. Service C must NOT be reachable through Nginx.
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/service-c)
[[ "$code" == "404" ]]
check "Service C not routable through Nginx (got HTTP $code, want 404)" "$?"

# 5. Invalid route returns a structured 404, not Nginx's default error page.
curl -s http://localhost/whatever | grep -q '"error"'
check "Unknown route returns JSON 404" "$?"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
exit $?
