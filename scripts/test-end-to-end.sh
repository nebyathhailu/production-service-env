#!/usr/bin/env bash
# Quick end-to-end sanity check for the whole stack: Nginx -> ride-api ->
# matching-service -> dispatch-service -> ride-api callback, plus the
# network-security boundary (matching-service not reachable through Nginx).
# Run after deploying, after a reboot, or any time you want a fast
# "is everything actually working" check.
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

# 1. ride-api health, through Nginx.
curl -s http://localhost/ride-api/health | grep -q '"status":"healthy"'
check "ride-api health check (through Nginx)" "$?"

# 2. Full request flow: Nginx -> ride-api -> matching-service -> dispatch-service -> ride-api callback.
curl -s http://localhost/ride-api/request-ride | grep -q '"status":"success"'
check "Full request flow (ride-api -> matching-service -> dispatch-service -> callback)" "$?"

# 3. matching-service must NOT be reachable through Nginx.
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/matching-service)
[[ "$code" == "404" ]]
check "matching-service not routable through Nginx (got HTTP $code, want 404)" "$?"

# 4. dispatch-service must NOT be reachable through Nginx.
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/dispatch-service)
[[ "$code" == "404" ]]
check "dispatch-service not routable through Nginx (got HTTP $code, want 404)" "$?"

# 5. Invalid route returns a structured 404, not Nginx's default error page.
curl -s http://localhost/whatever | grep -q '"error"'
check "Unknown route returns JSON 404" "$?"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
exit $?
