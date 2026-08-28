# AWS Redeployment Assessment — Group 1

**Status (2026-08-28): complete for the IaC ECS environment (Env B).**
Live proof and the submit pack: [production-readiness.md](production-readiness.md) · [evidence/EVIDENCE.md](evidence/EVIDENCE.md).

**Live account:** `240462142849` · **Region:** `us-east-1` · **Profile:** `devops-lab-new`
**Historical console account:** `827478161993` ([aws-ecs-phase1-and-plan.md](aws-ecs-phase1-and-plan.md))

Request flow: Internet → ALB:80 → ride-api:3001 → matching-service:3002 → dispatch-service:3003 → callback ride-api:3001.

---

## Environments

| Env | What | Status |
|---|---|---|
| **A** | Console ECS (`devops-g1-cluster`) in `827478161993` | Historical. Do not manage with this Terraform. |
| **B** | IaC ECS (`devops-g1-iac-*`) in `240462142849` | **Live. This is the submission target.** |
| **C** | LocalStack EC2 + nginx + Secrets Manager | Out of scope. `feat/module-service` / PR #42 (`modules/data`) — leave unmerged unless asked. |

Env B: custom VPC `10.1.0.0/16`, private Fargate (no public IP, no NAT, VPC endpoints), Service Connect `devops-g1-iac.internal`, ALB in front of ride-api only, OpenTofu state in `devops-g1-iac-tfstate-new`.

---

## Ownership and what each person delivered

| Person | Service | Platform | Live result |
|---|---|---|---|
| Meron | ride-api, desired 2, ALB-attached, `MATCHING_SERVICE_URL` | Cluster, namespace, shared module, first platform apply | 2/2 running, image `15e1aea-amd64`, both TG targets healthy |
| Rigbe | matching-service, `DISPATCH_SERVICE_URL` | ALB + target group | 1/1 running, image `f4d49be-amd64` |
| Nebyat | dispatch-service, `RIDE_API_URL`, C→A SG | State backend; GitHub OIDC | 1/1 running, image `570e4ab`; OIDC role live |

---

## Dependencies that had to line up

- SG handshake: ALB+C → A:3001; A → B:3002; B → C:3003. No A → C. Implemented as separate `aws_vpc_security_group_ingress_rule` resources to avoid the A→B→C→A Terraform cycle.
- Service Connect names must match env vars (app defaults use `*.internal` — the documented DNS scar). All three URLs are set on the task definitions.
- ECR repos `devops-g1-{ride-api,matching-service,dispatch-service}` are **data sources only**. Terraform never creates/deletes them. Images must exist before apply.

---

## What we ran to finish the migration

1. New SSO profile `devops-lab-new` → account `240462142849`.
2. Meron: bootstrap + platform + Service A. Rigbe: Service B. Nebyat: Service C image `570e4ab` + OIDC (PR #41).
3. E2E initially 502: ride-api called `matching-service.internal`. Fixed with `MATCHING_SERVICE_URL` (PR #43) and rolling deploys so Service Connect sidecars picked up B and C.
4. Confirmed `POST /request-ride` → 200, `request_id=SUBMIT-TRACE-001` on A, B, C including `/driver-assigned`.

---

## Config still required at runtime

| Item | Value |
|---|---|
| Env | `BIND_HOST=0.0.0.0`; A `MATCHING_SERVICE_URL`; B `DISPATCH_SERVICE_URL`; C `RIDE_API_URL` |
| Secrets / DB | None in Env B |
| IAM | Execution role (ECR + logs); task roles (`ssmmessages:*`); GitHub OIDC role (ECR push + ECS deploy + scoped `PassRole`) |
| Tags | `Project=devops-mentorship`, `Group=group-1`, `Owner=…`, `Environment=lab` |

---

## Risks we already paid for

- Service Connect DNS + callback SG (scar log Entry 4, repeated on this account).
- Apple Silicon `linux/amd64` image platform.
- Two ALBs if Env A were still running in another account — this submission only bills Env B.
- **PR #42 is not part of this submit.** Merging it would add RDS/Secrets Manager that this cluster does not use.
