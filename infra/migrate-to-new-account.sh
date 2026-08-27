#!/usr/bin/env bash
# One-shot script for the "Meron" portion of the new-account migration
# (docs/terraform-gate1-design.md / team-action-plan). Run this ONLY after
# `aws configure --profile devops-lab-new` has already been done with the real credentials —
# this script deliberately never touches credentials itself.
#
# Usage:
#   ./infra/migrate-to-new-account.sh <service_a_image_tag>
#
# What it does, in order:
#   1. Confirms the devops-lab-new profile actually resolves to a real, non-old account
#   2. Checks the state bucket name is free; if not, offers the fallback name
#   3. Applies the bootstrap stack fresh
#   4. Re-inits and applies the platform layer + Service A
#   5. Runs the pre-apply safety check before the real apply
#   6. Verifies Service A live, independently, not just trusting apply's exit code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="devops-lab-new"
REGION="us-east-1"
OLD_ACCOUNT_ID="827478161993"
BUCKET_NAME="devops-g1-iac-tfstate"
FALLBACK_BUCKET_NAME="devops-g1-iac-tfstate-v2"

SERVICE_A_TAG="${1:?Usage: $0 <service_a_image_tag>  (e.g. the current ride-api Git SHA, e.g. ab4aa5d-amd64)}"

echo "== Step 0: verifying devops-lab-new credentials =="
if ! aws sts get-caller-identity --profile "$PROFILE" >/tmp/caller-identity.json 2>&1; then
  echo "ERROR: profile '$PROFILE' is not configured or credentials are invalid."
  echo "Run: aws configure --profile $PROFILE   (with the real credentials from Rob's DM)"
  exit 1
fi

NEW_ACCOUNT_ID=$(jq -r '.Account' /tmp/caller-identity.json)
echo "Resolved account: $NEW_ACCOUNT_ID"

if [ "$NEW_ACCOUNT_ID" = "$OLD_ACCOUNT_ID" ]; then
  echo "ERROR: devops-lab-new resolves to the OLD account ($OLD_ACCOUNT_ID)."
  echo "This is not a new account. Stopping — re-check the credentials you configured."
  exit 1
fi

echo "Confirmed: new account is $NEW_ACCOUNT_ID (not the old account). Proceeding."
echo ""

echo "== Step 1: filling in allowed_account_ids in both provider.tf files =="
for f in "$SCRIPT_DIR/bootstrap/provider.tf" "$SCRIPT_DIR/environments/lab/provider.tf"; do
  if grep -q "allowed_account_ids" "$f"; then
    echo "  $f already has allowed_account_ids set — leaving it as-is (edit manually if it's wrong)."
  else
    # Insert allowed_account_ids right after the profile line, matching the file's existing style.
    python3 - "$f" "$NEW_ACCOUNT_ID" <<'PYEOF'
import sys
path, account_id = sys.argv[1], sys.argv[2]
with open(path) as fh:
    content = fh.read()
marker = '  profile = "devops-lab-new"\n'
insert = f'  profile = "devops-lab-new"\n\n  allowed_account_ids = ["{account_id}"] # hard-fail if the wrong AWS identity is ever picked up\n'
if marker in content and insert not in content:
    content = content.replace(marker, insert, 1)
    with open(path, 'w') as fh:
        fh.write(content)
    print(f"  updated {path}")
else:
    print(f"  {path}: marker not found or already updated, left as-is — check manually")
PYEOF
  fi
done
echo ""

echo "== Step 2: checking state bucket name availability =="
if aws s3api head-bucket --bucket "$BUCKET_NAME" --profile "$PROFILE" --region "$REGION" 2>/dev/null; then
  echo "  '$BUCKET_NAME' already exists and is reachable in this account/session — reusing it."
  ACTUAL_BUCKET="$BUCKET_NAME"
else
  # head-bucket exits non-zero for both "doesn't exist" (404) and "exists elsewhere, no access" (403).
  # Distinguish by checking the actual HTTP-ish error, since aws cli surfaces this in stderr.
  ERR=$(aws s3api head-bucket --bucket "$BUCKET_NAME" --profile "$PROFILE" --region "$REGION" 2>&1 || true)
  if echo "$ERR" | grep -qi "403\|Forbidden"; then
    echo "  '$BUCKET_NAME' is taken by someone else (403) — falling back to '$FALLBACK_BUCKET_NAME'."
    ACTUAL_BUCKET="$FALLBACK_BUCKET_NAME"
    sed -i.bak "s/$BUCKET_NAME/$FALLBACK_BUCKET_NAME/" "$SCRIPT_DIR/bootstrap/main.tf"
    sed -i.bak "s/$BUCKET_NAME/$FALLBACK_BUCKET_NAME/" "$SCRIPT_DIR/environments/lab/versions.tf"
    rm -f "$SCRIPT_DIR/bootstrap/main.tf.bak" "$SCRIPT_DIR/environments/lab/versions.tf.bak"
    echo "  Updated both files to use '$FALLBACK_BUCKET_NAME'."
  else
    echo "  '$BUCKET_NAME' is free (404/NotFound) — using it as-is."
    ACTUAL_BUCKET="$BUCKET_NAME"
  fi
fi
echo ""

echo "== Step 3: applying bootstrap stack =="
cd "$SCRIPT_DIR/bootstrap"
tofu init
tofu plan -out=tfplan
tofu apply "tfplan"
echo ""

echo "== Step 4: applying platform layer + Service A =="
cd "$SCRIPT_DIR/environments/lab"
tofu init -reconfigure
tofu plan -var="service_a_image_tag=$SERVICE_A_TAG" -out=tfplan
tofu show -json tfplan > tfplan.json

echo "== Step 5: pre-apply safety check =="
if ! ../../tests/check-no-existing-resources.sh tfplan.json; then
  echo "ERROR: safety check failed. Not applying. Review the plan before proceeding."
  exit 1
fi

tofu apply "tfplan"
echo ""

echo "== Step 6: independent verification (not trusting apply's exit code alone) =="
sleep 5
aws ecs describe-services \
  --cluster devops-g1-iac-cluster \
  --services devops-g1-iac-ride-api-svc \
  --profile "$PROFILE" --region "$REGION" \
  --query 'services[0].{status:status,running:runningCount,desired:desiredCount}' \
  --output json

echo ""
echo "Done. If running != desired above, wait ~30s and re-run the describe-services command"
echo "above manually, or check 'aws ecs describe-services ... --query services[0].events[0:5]'"
echo "for the reason if it's stuck."
echo ""
echo "State bucket used: $ACTUAL_BUCKET"
echo "New account ID: $NEW_ACCOUNT_ID"
echo "Post both of these in the group chat so Rigbe and Nebyat can proceed."
