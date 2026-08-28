# GitHub Actions → AWS auth via OIDC (new-account migration)

Track 2 of the account-migration plan. Replaces long-lived AWS keys in CI with a
short-lived, OIDC-federated role assumption. No secret access keys are stored in GitHub.

## Files

| File | Purpose |
|---|---|
| `github-oidc-trust.json` | Trust policy for `devops-g1-github-actions-role` — lets this repo's Actions runs assume the role via `sts:AssumeRoleWithWebIdentity` |
| `github-actions-permissions-policy.json` | Permissions the role grants: ECR auth + push (3 repos), ECS deploy, scoped `iam:PassRole` for the IaC task/execution roles |

Both files use the placeholder `<NEW_ACCOUNT_ID>`. Substitute the real new account ID before
applying — get it with `aws sts get-caller-identity --profile devops-lab-new --query Account`.

## Provisioning (run once, after new-account access is confirmed)

These are live IAM operations — run them yourself with the `devops-lab-new` profile.

```bash
cd aws/github-actions
NEW_ACCOUNT_ID=$(aws sts get-caller-identity --profile devops-lab-new --query Account --output text)
sed -i "s/<NEW_ACCOUNT_ID>/$NEW_ACCOUNT_ID/g" github-oidc-trust.json github-actions-permissions-policy.json

# 1. OIDC identity provider (one per account; skip if it already exists)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  --profile devops-lab-new

# 2. The role, with the trust policy
aws iam create-role \
  --role-name devops-g1-github-actions-role \
  --assume-role-policy-document file://github-oidc-trust.json \
  --profile devops-lab-new

# 3. Attach the permissions policy inline
aws iam put-role-policy \
  --role-name devops-g1-github-actions-role \
  --policy-name devops-g1-github-actions-permissions \
  --policy-document file://github-actions-permissions-policy.json \
  --profile devops-lab-new
```

## Wire the workflow

Already done in `.github/workflows/container-ci-cd.yml`:

- `id-token: write` added to top-level `permissions`.
- A `Configure AWS credentials` step (`aws-actions/configure-aws-credentials@v4`) added to the
  `publish` job before the Docker Hub login, assuming the role above.

**One manual step in GitHub:** set the repository variable `AWS_ACCOUNT_ID` to the new account ID
(Settings → Secrets and variables → Actions → Variables). The credentials step is gated on this
variable, so it stays skipped (not failing) until it's set — then it runs and goes green.

## Verify

Trigger a run (push to `main` or `workflow_dispatch`) and confirm the **Configure AWS credentials**
step in the `publish` job succeeds in the Actions tab.
