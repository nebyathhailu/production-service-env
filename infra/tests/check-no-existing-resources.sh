#!/usr/bin/env bash
# Pre-apply safety check: fails loudly if a `terraform/tofu plan` output references any
# resource ID belonging to the existing console-built environment (docs/terraform-gate1-design.md
# §0). Run this against a saved plan file before every apply, not just once.
#
# Usage:
#   tofu plan -out=tfplan
#   tofu show -json tfplan > tfplan.json
#   ./infra/tests/check-no-existing-resources.sh tfplan.json

set -euo pipefail

PLAN_JSON="${1:?Usage: $0 <plan.json> (produced via 'tofu show -json <planfile>')}"

# Known existing resource identifiers that must NEVER appear in this assignment's plan output —
# neither as something created, modified, nor destroyed. Sourced from the live inventory in
# docs/terraform-gate1-design.md §0 (verified 2026-08-04).
EXISTING_RESOURCE_IDS=(
  "devops-g1-cluster"
  "devops-g1-alb"
  "group1.internal"
  "devops-g1-ride-api"
  "devops-g1-matching-service"
  "devops-g1-dispatch-service"
  "vpc-050f3fbaf6bd956a6"
)

if [ ! -f "$PLAN_JSON" ]; then
  echo "ERROR: plan JSON file not found: $PLAN_JSON" >&2
  exit 2
fi

FOUND_ANY=0
for id in "${EXISTING_RESOURCE_IDS[@]}"; do
  if grep -q -- "$id" "$PLAN_JSON"; then
    echo "BLOCKED: plan references existing resource identifier: $id"
    echo "  This assignment must never create, modify, or destroy anything from the existing"
    echo "  console-built environment. Review the plan and the resource/data-source block that"
    echo "  produced this match before proceeding."
    FOUND_ANY=1
  fi
done

if [ "$FOUND_ANY" -eq 1 ]; then
  echo ""
  echo "Pre-apply safety check FAILED. Do not apply this plan."
  exit 1
fi

echo "Pre-apply safety check passed: no existing-environment resource identifiers found in plan."
exit 0
