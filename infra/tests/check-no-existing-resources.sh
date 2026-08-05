#!/usr/bin/env bash
# Pre-apply safety check: fails loudly if a `terraform/tofu plan` output would CREATE, UPDATE,
# or DELETE any resource belonging to the existing console-built environment
# (docs/terraform-gate1-design.md §0). Run this against a saved plan's JSON output before every
# apply, not just once.
#
# Deliberately does NOT flag read-only `data` source lookups against existing resources (e.g.
# the existing ECR repos, referenced read-only per Gate 1 §8's approved image-path decision) —
# only actions with a real, mutating "change" action count as a violation.
#
# Requires: jq
#
# Usage:
#   tofu plan -out=tfplan
#   tofu show -json tfplan > tfplan.json
#   ./infra/tests/check-no-existing-resources.sh tfplan.json

set -euo pipefail

PLAN_JSON="${1:?Usage: $0 <plan.json> (produced via 'tofu show -json <planfile>')}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: this script requires jq. Install it (e.g. 'brew install jq') and re-run." >&2
  exit 2
fi

if [ ! -f "$PLAN_JSON" ]; then
  echo "ERROR: plan JSON file not found: $PLAN_JSON" >&2
  exit 2
fi

# Known existing resource identifiers that must never be created, updated, or deleted by this
# assignment's Terraform. Sourced from the live inventory in docs/terraform-gate1-design.md §0.
EXISTING_RESOURCE_IDS=(
  "devops-g1-cluster"
  "devops-g1-alb"
  "group1.internal"
  "devops-g1-ride-api"
  "devops-g1-matching-service"
  "devops-g1-dispatch-service"
  "vpc-050f3fbaf6bd956a6"
)

# Only flag a resource_changes entry when one of the KNOWN EXISTING IDENTIFIERS appears in a
# field that actually IDENTIFIES the resource being acted on — its address, its "name"/"id"
# planned value (pre-apply, i.e. an explicit name we set, like a hardcoded bucket/cluster
# name), NOT arbitrary attribute values like a container image URI that merely *references*
# an existing resource without creating/modifying/deleting it. This intentionally allows the
# Gate-1-approved pattern of reading the existing ECR repos via read-only data source and using
# their repository_url inside a brand-new task definition's image field.
MUTATING_CHANGES=$(jq -c '
  .resource_changes[]
  | select(.mode == "managed")
  | select((.change.actions | index("no-op")) | not)
  | select((.change.actions | index("delete")) or (.change.actions | index("update")) or
           (.change.after.name != null or .change.after.id != null))
' "$PLAN_JSON")

FOUND_ANY=0
for id in "${EXISTING_RESOURCE_IDS[@]}"; do
  MATCHES=$(echo "$MUTATING_CHANGES" | jq -c --arg id "$id" '
    select(.address == $id or .change.after.name == $id or .change.after.id == $id or
           (.address | contains($id)))
  ')
  if [ -n "$MATCHES" ]; then
    echo "BLOCKED: a real (create/update/delete) plan action targets existing resource identifier: $id"
    echo "  This assignment must never create, modify, or destroy anything from the existing"
    echo "  console-built environment. Review the resource_changes entry below before proceeding:"
    echo "$MATCHES" | jq -r '"    address=" + .address + " actions=" + (.change.actions | join(","))'
    FOUND_ANY=1
  fi
done

if [ "$FOUND_ANY" -eq 1 ]; then
  echo ""
  echo "Pre-apply safety check FAILED. Do not apply this plan."
  exit 1
fi

echo "Pre-apply safety check passed: no create/update/delete action on any existing-environment resource."
exit 0
