# Gate 1 Submission — Group 1 (ECS on Fargate)

**Group:** 1 · **Region:** `us-east-1` · **Account:** `827478161993` · **Prefix:** `devops-g1-`
**Namespace:** `group1.internal` · **Status:** No AWS resources created (Gate 1 is pre-build)

> Everything below is grounded in the actual codebase in this repo (`services/*/app.py`,
> `docker-compose.yml`, each `Dockerfile`), not just the plan. Where the plan and the code agree,
> the code is cited as evidence.

---

## 1. Dependency graph

```
IAM identity
    |
Assigned Region (us-east-1)
    |
Default VPC
    |
Default subnets in two Availability Zones
    |
Security groups
    |
ECR repositories
    |
ECS cluster
    |
Task definitions
    |
ECS services
    |
Service Connect namespace (group1.internal)
    |
Target group
    |
Application Load Balancer
    |
DNS
```

Attached to the chain (cross-cutting): CloudWatch Logs, CodeConnections, CodePipeline, CodeBuild,
ECS deployment.

**Why this order (each link is a precondition for the next):**

- **IAM identity** — AWS must know who is asking before anything else happens. Floor of the chain.
- **Region** — every resource lives in exactly one region; building in the wrong one produces
  resources the rest of the team can't see.
- **Default VPC + subnets in two AZs** — two AZs so a single data-center (AZ) outage doesn't take
  the service down; the surviving AZ keeps serving.
- **Security groups** — must exist before a task launches, or the task is either unreachable or
  dangerously open.
- **ECR repositories** — a container needs an already-pushed image to run.
- **ECS cluster** — a logical grouping only; runs no compute itself.
- **Task definitions** — the recipe (image, CPU/memory, port, env, permissions). Nothing runs
  without it.
- **ECS services** — keep N copies of a task alive and replace dead ones. The task def alone is
  just a document.
- **Service Connect namespace** — lets services resolve each other by name
  (`http://matching-service:3002`) instead of by ever-changing task IPs.
- **Target group → ALB → DNS** — the public door. ALB needs a target group to know where to send
  traffic; DNS maps a human name to the ALB.

**Senior takeaway:** almost every real outage in a system this shape is one silently broken link
(a forgotten SG rule, a task role missing one permission), not the whole system failing at once.

---

## 2. Three failure predictions

These are hypotheses about how ECS/ALB behave — to be confirmed against this account after deploy.

| # | Broken edge | Expected user symptom | Expected AWS evidence |
|---|---|---|---|
| 1 | ECS task → ECR (wrong SHA tag, or execution role missing ECR pull) | Task never reaches RUNNING | Repeated STOPPED tasks in ECS console; stopped-reason mentions image pull failure |
| 2 | ALB target group → container port (wrong port, or app bound to `127.0.0.1`) | Requests to ALB time out / 502 / 503 | Target group shows targets **unhealthy**; `/health` check failing |
| 3 | ride-api → matching-service (Service Connect name mismatch or wrong `*_URL` env) | Chain breaks after ride-api; ride request never completes | ride-api CloudWatch logs show connection/DNS failure reaching `matching-service` |

**Codebase note on #2 (real trap for us):** all three apps default `BIND_HOST` to `127.0.0.1`
(`services/ride-api/app.py:30`, `matching-service/app.py:30`, `dispatch-service/app.py:30`).
`docker-compose.yml` overrides it to `0.0.0.0`. On AWS the task definition **must** set
`BIND_HOST=0.0.0.0`, or the app binds to localhost and every health check fails — matching
prediction #2 exactly.

---

## 3. Traffic contracts

Intended path — no other application path is permitted:

```
Internet → ALB → ride-api → matching-service → dispatch-service → callback to ride-api
```

### Allow / deny matrix

| Source | Destination | Port | Allowed? | Enforcement |
|---|---|---|---|---|
| Internet | ALB | 80 | Yes | ALB security group |
| Internet | ride-api | 3001 | No | ride-api SG (no internet inbound) |
| Internet | matching-service | 3002 | No | matching-service SG |
| Internet | dispatch-service | 3003 | No | dispatch-service SG |
| ALB | ride-api | 3001 | Yes | ALB SG → ride-api SG |
| ride-api | matching-service | 3002 | Yes | ride-api SG → matching-service SG |
| ride-api | dispatch-service | 3003 | **No** | No matching rule (least privilege) |
| matching-service | dispatch-service | 3003 | Yes | matching-service SG → dispatch-service SG |

### Per-pair contract (protocol, port, name, SG, health, timeout)

| Pair | Protocol | Port | Service Connect name | SG reference | Health | Timeout |
|---|---|---|---|---|---|---|
| ALB → ride-api | HTTP | 3001 | ride-api | alb-sg → ride-api-sg | /health | 5s |
| ride-api → matching-service | HTTP | 3002 | matching-service | ride-api-sg → matching-service-sg | /health | 5s |
| matching-service → dispatch-service | HTTP | 3003 | dispatch-service | matching-service-sg → dispatch-service-sg | /health | 5s |

**Ports / names verified in code:** ride-api `3001` (`ride-api/app.py:30`), matching-service
`3002` (`matching-service/app.py:29`), dispatch-service `3003` (`dispatch-service/app.py:29`).
Each `Dockerfile` `EXPOSE`s and health-checks the same port. Every service serves `/health`
(e.g. `dispatch-service/app.py:121`).

**Timeout = 5s** matches `DOWNSTREAM_TIMEOUT=5` already used by the code
(`docker-compose.yml`, and default in each `app.py:32`). Keeping the AWS value identical means
local and AWS fail the same way under the same conditions, so these predictions stay valid.

**Downstream calls are by name, not IP (verified):** each service reads its downstream from an env
var — `MATCHING_SERVICE_URL` (`ride-api/app.py:32`), `DISPATCH_SERVICE_URL`
(`matching-service/app.py:31`), `RIDE_API_URL` for the callback (`dispatch-service/app.py:31`).
Code defaults even use `.internal` hostnames, so wiring them to Service Connect names on AWS is a
config change, not a code change.

**Why `ride-api → dispatch-service` is denied:** the app flow is strictly A→B→C, never A→C — no
code path in ride-api calls dispatch-service. Leaving A→C open would break nothing today but is a
least-privilege weakness: if ride-api were compromised, an open A→C path hands an attacker a route
to dispatch-service the architecture never intended. This mirrors the local Docker `internal: true`
network, re-implemented with security groups.

**Lab networking note:** tasks run in default public subnets with public IPs for outbound. Public
IP ≠ publicly permitted — the SGs still block direct inbound to the app services. Private
subnets / NAT / VPC endpoints are out of scope.

---

## 4. Resource ownership

| Role | Person | Responsibilities |
|---|---|---|
| Person 1 — ride-api owner | _(claim)_ | ride-api image/ECR/task-def/SG/service/pipeline **+ ECS cluster + Service Connect namespace** |
| Person 2 — matching-service owner | _(claim)_ | matching-service image/ECR/task-def/SG/service/pipeline **+ ALB + target group** |
| Person 3 — dispatch-service owner | _(claim)_ | dispatch-service image/ECR/task-def/SG/service/pipeline **+ CodeConnections** |

Platform pieces are split by which service work touches them earliest (cluster/namespace early →
P1; ALB once ride-api exists → P2; CodeConnections only in Phase 5 → P3). No rotation. You may
advise another owner but never operate their console.

---

## 5. Expected resource names (Group 1)

| Resource | Name |
|---|---|
| ECR — ride-api | `devops-g1-ride-api` |
| ECR — matching-service | `devops-g1-matching-service` |
| ECR — dispatch-service | `devops-g1-dispatch-service` |
| ECS cluster | `devops-g1-cluster` |
| Task def — ride-api | `devops-g1-ride-api` (family) |
| Task def — matching-service | `devops-g1-matching-service` (family) |
| Task def — dispatch-service | `devops-g1-dispatch-service` (family) |
| ECS service — ride-api | `devops-g1-ride-api-svc` |
| ECS service — matching-service | `devops-g1-matching-service-svc` |
| ECS service — dispatch-service | `devops-g1-dispatch-service-svc` |
| SG — ALB | `devops-g1-alb-sg` |
| SG — ride-api | `devops-g1-ride-api-sg` |
| SG — matching-service | `devops-g1-matching-service-sg` |
| SG — dispatch-service | `devops-g1-dispatch-service-sg` |
| Service Connect namespace | `group1.internal` |
| Log group — ride-api | `/ecs/devops-g1-ride-api` |
| Log group — matching-service | `/ecs/devops-g1-matching-service` |
| Log group — dispatch-service | `/ecs/devops-g1-dispatch-service` |
| ALB | `devops-g1-alb` |
| Target group | `devops-g1-ride-api-tg` |
| CodeConnections connection | `devops-g1-github-connection` |
| CodeBuild — ride-api | `devops-g1-ride-api-build` |
| CodeBuild — matching-service | `devops-g1-matching-service-build` |
| CodeBuild — dispatch-service | `devops-g1-dispatch-service-build` |
| CodePipeline — ride-api | `devops-g1-ride-api-pipeline` |
| CodePipeline — matching-service | `devops-g1-matching-service-pipeline` |
| CodePipeline — dispatch-service | `devops-g1-dispatch-service-pipeline` |

**Required tags on every resource:** `Project=devops-mentorship`, `Group=group-1`,
`Owner=<service>-owner` / `platform-owner`, `Environment=lab`. **Image tag = Git commit SHA,
never `latest`.**

---

## Gate 1 submission checklist

- [x] Dependency graph (§1)
- [x] Three failure predictions (§2)
- [x] Traffic contracts (§3)
- [x] Resource ownership (§4)
- [x] Expected resource names (§5)

**No resources exist in AWS. Awaiting instructor review before any build begins.**
