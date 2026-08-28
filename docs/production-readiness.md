# Group 1 — Production Readiness (new-account IaC lab)

**Status:** ready to submit (captured 2026-08-28).
**Account:** `240462142849` (AkiraChix) · **Region:** `us-east-1` · **CLI profile:** `devops-lab-new`
**Prefix:** `devops-g1-iac-` · **This is the environment to grade.**

The earlier console-built cluster in account `827478161993` is historical
([aws-ecs-phase1-and-plan.md](aws-ecs-phase1-and-plan.md)). Do not mix identifiers.

Request chain: `Internet → ALB:80 → ride-api:3001 → matching-service:3002 → dispatch-service:3003 → callback ride-api:3001`.

---

## 1. What is live

| Resource | Value |
|---|---|
| ECS cluster | `devops-g1-iac-cluster` |
| ALB | `devops-g1-iac-alb` · `devops-g1-iac-alb-207582331.us-east-1.elb.amazonaws.com` |
| Target group | `devops-g1-iac-svc-a-tg` (type `ip`, `/health`, both AZ targets healthy) |
| Namespace | `devops-g1-iac.internal` |
| VPC | custom `10.1.0.0/16`, tasks in private subnets, **no public IP**, no NAT, VPC endpoints for ECR/Logs/SSM |
| State | S3 `devops-g1-iac-tfstate-new`, OpenTofu ≥1.10 native lock |
| CI auth | GitHub OIDC → `devops-g1-github-actions-role` (no long-lived keys) |

| Service | Owner | Desired / running | Image (never `latest`) | Service Connect URL env |
|---|---|---|---|---|
| ride-api (A) | Meron | 2 / 2 | `devops-g1-ride-api:15e1aea-amd64` · task def rev 2 | `MATCHING_SERVICE_URL=http://matching-service:3002` |
| matching-service (B) | Rigbe | 1 / 1 | `devops-g1-matching-service:f4d49be-amd64` · rev 1 | `DISPATCH_SERVICE_URL=http://dispatch-service:3003` |
| dispatch-service (C) | Nebyat | 1 / 1 | `devops-g1-dispatch-service:570e4ab` · rev 1 | `RIDE_API_URL=http://ride-api:3001` |

All three: Fargate, circuit breaker + rollback, ECS Exec, CloudWatch `/ecs/devops-g1-iac-<service>`.

---

## 2. Production-readiness checklist

| Area | How this lab meets it | Evidence |
|---|---|---|
| Public entry is only the ALB | Only ride-api registers with the ALB. B and C have no target group. | TG `devops-g1-iac-svc-a-tg`; B/C `register_with_alb = false` |
| Least-privilege traffic | SG *references*, not CIDRs, on app ports. A→C has no rule. C→A callback is explicit. | §4 below |
| Private compute | `assign_public_ip = false` hardcoded in `modules/ecs-service`. | Task ENIs have no public IP; VPC endpoints for AWS APIs |
| Immutable release | Image tags are Git SHAs; module rejects `latest`. ECR `IMMUTABLE`. | Live image URIs in §1 |
| Hands-off delivery | Merge to `main` → GitHub Actions OIDC → ECR. ECS rolling deploy + circuit breaker. | [aws/github-actions/README.md](../aws/github-actions/README.md), PR #41 |
| Health + recovery | ALB `/health`; two ride-api tasks in different AZs; matching/dispatch force-replaced recovered DNS. | Both TG targets `healthy`; E2E 200 |
| Correlation | Same `request_id` + `trace_id` on A, B, C including the callback. | `SUBMIT-TRACE-001` in [EVIDENCE.md](evidence/EVIDENCE.md) |
| Reproducible infra | OpenTofu modules + remote locked state. Destroy/rebuild does not touch ECR. | [infra/README.md](../infra/README.md) |
| Cost / cleanup | ALB + Fargate bill while idle. Cleanup order documented. | §6 |
| Tags | `Project=devops-mentorship`, `Group=group-1`, `Owner=…`, `Environment=lab` | provider `default_tags` + per-service Owner |

---

## 3. Ownership (what each person is responsible for)

Fixed service ownership across the migration:

| Person | Service | Platform |
|---|---|---|
| **Meron** | ride-api — desired 2, ALB registration, `MATCHING_SERVICE_URL` | Cluster, Service Connect namespace, shared `ecs-service` module, bootstrap/network apply |
| **Rigbe** | matching-service — `DISPATCH_SERVICE_URL` | ALB + target group |
| **Nebyat** | dispatch-service — `RIDE_API_URL`, C→A SG on ride-api | State backend; GitHub OIDC for Actions |

Live evidence for **all three** services is in [evidence/EVIDENCE.md](evidence/EVIDENCE.md). Nobody needs a separate private proof pack to submit.

---

## 4. Traffic contract (enforced live)

| Source | Destination | Port | Result | Live SG |
|---|---|---|---|---|
| Internet | ALB | 80 | Allow | `devops-g1-iac-alb-sg` `0.0.0.0/0` |
| ALB `sg-0333a8fc33908f83d` | ride-api | 3001 | Allow | ride-api SG |
| dispatch-service `sg-07b992f7224a76e9a` | ride-api | 3001 | Allow (callback) | ride-api SG |
| ride-api `sg-04cb87c3a8a99573d` | matching-service | 3002 | Allow | matching SG |
| matching-service `sg-05d06e8ca1b8d94ce` | dispatch-service | 3003 | Allow | dispatch SG |
| Internet | A/B/C app ports | any | Deny | no `0.0.0.0/0` on 3001/3002/3003; no public IP |
| ride-api | dispatch-service | 3003 | Deny | no matching ingress rule |

---

## 5. How to prove it in 60 seconds

```bash
export AWS_PROFILE=devops-lab-new AWS_REGION=us-east-1 AWS_PAGER=""
export ALB=devops-g1-iac-alb-207582331.us-east-1.elb.amazonaws.com
export CL=devops-g1-iac-cluster

aws ecs describe-services --cluster $CL \
  --services devops-g1-iac-ride-api-svc devops-g1-iac-matching-service-svc devops-g1-iac-dispatch-service-svc \
  --query 'services[].{name:serviceName,desired:desiredCount,running:runningCount}'

curl -s http://$ALB/health
curl -s -X POST http://$ALB/request-ride -H 'Content-Type: application/json' \
  -H 'X-Request-ID: SUBMIT-TRACE-001' -d '{"rider":"submit"}'
```

Expected: desired/running 2/2, 1/1, 1/1; health `"status":"healthy"` with `"matching-service":"ok"`; POST `"status":"success"`.

---

## 6. Cost and cleanup

Billable while idle: Fargate tasks, ALB, VPC interface endpoints, CloudWatch logs, ECR storage.

Cleanup order (this IaC env only — never the default VPC):

```
scale ECS services to 0 or tofu destroy environments/lab
  → ALB / target group (destroyed with the env)
  → cluster
  → custom SGs / VPC endpoints
  → log groups
  → bootstrap bucket last, only if instructed
```

Do **not** delete the three ECR repositories unless instructed; they are the image source of record.

---

## 7. Known scars (already hit, already fixed)

1. **amd64 images** — Fargate rejects arm64 manifests. Build on this lab host with plain `docker build` (native amd64) or `buildx --platform linux/amd64` on Apple Silicon.
2. **Service Connect names** — app defaults use `*.internal`. Must set `MATCHING_SERVICE_URL`, `DISPATCH_SERVICE_URL`, `RIDE_API_URL` to the bare discovery names (`http://matching-service:3002`, etc.). PR #43.
3. **C→A callback** — SG rule on ride-api from dispatch-service, plus restarting dispatch after ride-api replacement so the sidecar can resolve `ride-api`.
4. **Layered 502** — a failed callback or B→C DNS miss surfaces as “Matching service unreachable” at the ALB. Always grep the same `request_id` in all three log groups.

---

## 8. Out of scope for this submission

- LocalStack EC2 + nginx rehost (`feat/module-service`) and **PR #42** (`modules/data`). Separate assignment; leave unmerged unless the instructor asks for it.
- The old console cluster (`devops-g1-cluster` in `827478161993`). Do not apply this Terraform there.

---

## 9. Doc index

| Doc | Role |
|---|---|
| This file | Production-readiness + submit checklist |
| [evidence/EVIDENCE.md](evidence/EVIDENCE.md) | Captured live transcripts (AWS + original VM pack) |
| [demo-runbook.md](demo-runbook.md) | Demo script; **new-account identifiers at the top** |
| [terraform-gate1-design.md](terraform-gate1-design.md) | Original IaC design (Gate 1; written against the old account) |
| [aws-ecs-phase1-and-plan.md](aws-ecs-phase1-and-plan.md) | Console-built lab (historical) |
| [redeployment-assessment.md](redeployment-assessment.md) | Pre-migration assessment; status now **complete** for Env B |
