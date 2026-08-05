# Assignment 1 — Greenfield ECS Fargate with Terraform/OpenTofu — Gate 1 Design

**Group number:** 1
**Assigned AWS region:** us-east-1
**AWS account ID:** 827478161993
**Resource naming prefix:** `devops-g1-`
**Due / live demo:** Wednesday, 5 August 2026
**Status:** Submitted for Gate 1 review.

## Objective

Build the same three-service system Group 1 already hosted through the AWS console — client →
ALB → ride-api → matching-service → dispatch-service, with ECS Service Connect wiring the internal
hops — a second time, entirely from Infrastructure as Code, so the team can prove the environment
is reproducible, secure by construction, and safe to destroy and rebuild without any console
intervention. This document is Gate 1: the design review required before any workload resource in
this assignment's scope is created.

This build is a **separate system** from the console-built environment in
`aws-ecs-phase1-and-plan.md`. That system stays live and untouched throughout this assignment —
the plan is to end up with two independent, fully working clusters side by side: the original
console-built one, and this new IaC-managed one.

The team reviewed the current live AWS account together before drafting this design, so every
fact below reflects what is actually running (`aws --profile devops-lab --region us-east-1`
describe/list calls, 2026-08-04) rather than what the prior assignment's docs said should be
running.

---

## 0. Scope boundary — what already exists and must not be touched

Live inventory, verified 2026-08-04:

| Resource | Value |
|---|---|
| ECS cluster | `devops-g1-cluster` |
| VPC | Default VPC `vpc-050f3fbaf6bd956a6`, CIDR `172.31.0.0/16` |
| ALB | `devops-g1-alb`, internet-facing, in public subnets `subnet-064c026c86b153f93` (1a) / `subnet-09c9060d43fef0c35` (1b) |
| ECS services | `ride-api` (desired 2, public subnets, public IP enabled), `matching-service` (desired 1, private subnets), `dispatch-service` (desired 1, private subnets) |
| Service Connect namespace | `group1.internal` |
| ECR repos | `devops-g1-ride-api`, `devops-g1-matching-service`, `devops-g1-dispatch-service` — all `IMMUTABLE` tag mutability |
| VPC endpoints | ECR API, ECR DKR, CloudWatch Logs, S3 (gateway), SSM, SSM Messages, EC2 Messages — all `available` |
| NAT gateways | None |

**This assignment's Terraform/OpenTofu state must never import or manage any resource in this
table.** The new greenfield VPC, subnets, ALB, and cluster will be entirely separate resources
with distinct names, so there is no accidental-overlap risk as long as we don't reuse
`devops-g1-cluster`, `devops-g1-alb`, `group1.internal`, or the existing ECR repos.

---

## 1. Dependency graph and ownership map

```text
                         ┌─────────────────────────┐
                         │   bootstrap stack        │
                         │   (S3 backend + lock)    │  Platform owner (rotates — see §8)
                         └────────────┬─────────────┘
                                      │ backend config
                                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      infra/environments/lab                          │
│                                                                        │
│  modules/network  ──▶  modules/alb  ──▶  modules/ecs-platform         │
│  (VPC, subnets,        (ALB, target       (cluster, Service Connect   │
│   routes, endpoints)    group)             namespace)                 │
│         │                    │                     │                  │
│         └────────────────────┴─────────────────────┘                  │
│                              │ outputs consumed by                    │
│                              ▼                                        │
│              modules/ecs-service (one reusable module)                │
│         ┌────────────────────┼────────────────────┐                   │
│         ▼                    ▼                    ▼                   │
│  instance: service-a   instance: service-b   instance: service-c      │
│  (ride-api)             (matching-service)    (dispatch-service)      │
│  Service A owner        Service B owner       Service C owner         │
└─────────────────────────────────────────────────────────────────────┘
```

**Build order (why):** network must exist before ALB (ALB needs public subnets), ALB and
ecs-platform (cluster + namespace) must both exist before any `ecs-service` instance (a service
needs a cluster to run in and, for service A, a target group to register with). Services B and C
depend on the platform outputs but not on the ALB directly (only service A registers with it).

**Ownership (design/build responsibility, per resource — distinct from the rotating
Platform/Release roles in §8):**

| Resource | Owner |
|---|---|
| `modules/network`, `modules/alb`, `modules/ecs-platform`, bootstrap stack, backend config | Platform owner (rotates by cycle) |
| Service A instantiation, ECR, task def, log group, SG, ALB registration | Meron |
| Service B instantiation, ECR, task def, log group, SG | Rigbe |
| Service C instantiation, ECR, task def, log group, SG | Nebyat |
| `modules/ecs-service` (the shared reusable module itself) | Meron merges, since the Cycle 1 Platform owner builds the platform-layer modules first and is first to need it; all three service owners instantiate the module and propose changes via PR |
| Plan summaries, approval evidence, image SHA selection, release proof | Release owner (rotates by cycle) |

---

## 2. CIDR and subnet-capacity table

This is a new, custom VPC — it does not reuse the default VPC's `172.31.0.0/16` range, keeping the
two clusters (old console-built, new IaC) unambiguously separate at the network level, not just by
naming.

CIDR: `10.1.0.0/16`, a block distinct from both the default VPC's `172.31.0.0/16` and common
home/office LAN ranges like `192.168.0.0/16`, so a future VPN or peering connection won't collide
with it.

| Subnet | AZ | CIDR | Usable IPs | Purpose |
|---|---|---|---|---|
| public-1 | us-east-1a | `10.1.0.0/24` | 251 | ALB, optional NAT |
| public-2 | us-east-1b | `10.1.1.0/24` | 251 | ALB, optional NAT |
| private-app-1 | us-east-1a | `10.1.10.0/24` | 251 | Fargate tasks (A, B, C) |
| private-app-2 | us-east-1b | `10.1.11.0/24` | 251 | Fargate tasks (A, B, C) |

**Rolling-deployment headroom check:** default desired counts are A=2, B=1, C=1 (4 tasks total at
steady state). ECS's default rolling deployment (`minimumHealthyPercent: 100`,
`maximumPercent: 200` unless overridden) can temporarily double a service's task count during a
deploy — worst case, service A briefly needs 4 tasks instead of 2. Total worst-case concurrent
tasks across both private-app subnets: A=4 + B=2 + C=2 = 8 tasks, split across 2 AZs ≈ 4 per
subnet. A `/24` (251 usable IPs) has enormous headroom for this — capacity is not a real
constraint at this task count. We sized each subnet at `/24` rather than a tighter `/26` so the
team never has to come back and re-plan the network as task counts grow; the extra IP space costs
nothing meaningful within a `/16`.

---

## 3. Route-table and egress design

This carries over the already-working decision from the console-built system: **no NAT gateway**.
The team confirmed by grepping application code in the prior assignment that none of the three
services make outbound calls to anything outside AWS-managed endpoints (ECR, CloudWatch Logs, SSM
for ECS Exec), and verified live that the existing private subnets run with zero NAT gateways,
routing only to a local target and an S3 gateway endpoint. The new VPC replicates that same
pattern.

| Route table | Associated subnets | Routes |
|---|---|---|
| public-rt | public-1, public-2 | `10.1.0.0/16` → local; `0.0.0.0/0` → Internet Gateway |
| private-rt | private-app-1, private-app-2 | `10.1.0.0/16` → local; S3 prefix list → S3 Gateway Endpoint |

**Required VPC endpoints (Interface, in private-app subnets)**, mirroring the verified working set
from the existing environment: `ecr.api`, `ecr.dkr`, `logs`, `ssmmessages`, `ssm`, `ec2messages`.
Plus one Gateway endpoint for `s3` (ECR stores image layers in S3; the DKR endpoint alone isn't
sufficient — this matches what's actually deployed and working today, not a guess).

**Trade-off:** VPC endpoints carry an hourly and per-GB cost, same as a NAT Gateway would, but they
avoid a public egress path and are scoped per-AWS-service rather than acting as a general internet
gateway. The running console system already proves this works and that nothing needs general
internet access, so endpoints are the right choice over NAT here (see decision card #2).

---

## 4. Security-group matrix and traffic contract

| Source | Destination | Port | Result | Notes |
|---|---|---|---|---|
| Internet (`0.0.0.0/0`) | ALB | 80 | Allow | Only public ingress point |
| ALB SG | Service A SG | A's app port | Allow | Target type `ip` |
| Service A SG | Service B SG | B's internal port | Allow | By SG reference, not CIDR |
| Service B SG | Service C SG | C's internal port | Allow | By SG reference, not CIDR |
| Service C SG | Service A SG | A's app port | Allow | **Callback leg** — verified live in the existing system: `describe-security-group-rules` on ride-api's SG shows an explicit ingress rule sourced from dispatch-service's SG on ride-api's port, and dispatch-service's task definition has `RIDE_API_URL=http://ride-api:3001` baked in as an env var, confirming the app code actually calls back. This is a real, evidence-backed exception to the strict A→B→C chain, not a spec violation — must be explicitly modeled, since the prior assignment's scar log (Entry 4) shows what happens when a traffic-contract table omits it: a 502 masquerading as a different service's failure, plus a second independent Service Connect DNS bug hiding behind the first. |
| Internet | Service A, B, or C directly | any | Deny | No public IP on any task; SGs don't allow `0.0.0.0/0` on app ports |
| Service A SG | Service C SG | C's internal port | Deny | Enforced by simply never adding this rule |
| VPC endpoint SG | — | 443 | Allow from A, B, C SGs | Needed for ECR/Logs/SSM access from private subnets |

**Note on the table above:** the assignment's own traffic contract (page 4 of the brief) lists only
the forward chain and an explicit "Service A → Service C: Deny" rule — it does not mention a C→A
callback edge as part of the *required* contract. Our application-level behavior includes that
callback, verified above against the live system, so our security-group matrix has one more row
than the assignment's minimum template. We're flagging this explicitly here so it reads as a
deliberate, evidence-backed addition rather than scope creep or an oversight.

---

## 5. Expected resource names and tags

All resources prefixed `devops-g1-`, distinct suffixes from the existing environment to guarantee
no collision (e.g. `devops-g1-iac-cluster` not `devops-g1-cluster`).

| Resource | Name |
|---|---|
| VPC | `devops-g1-iac-vpc` |
| ECS cluster | `devops-g1-iac-cluster` |
| Service Connect namespace | `devops-g1-iac.internal` (avoids any ambiguity with the existing `group1.internal`; this deviates from the brief's literal `group<n>.internal` pattern, for a real, unavoidable reason — HTTP namespace names must be unique per account, and `group1.internal` already exists and is in active use. **Action item: confirm with the instructor before first apply that a suffixed namespace name is acceptable**, so this reads as an approved, evidence-backed decision rather than a silently skipped requirement.) |
| ALB | `devops-g1-iac-alb` |
| ECR repos | **Not created new.** This build references the three existing repos — `devops-g1-ride-api`, `devops-g1-matching-service`, `devops-g1-dispatch-service` — as read-only Terraform data sources, not managed resources. See §8 for why: the existing CI pipelines already push SHA-tagged images to these repos, and creating parallel `-iac-` repos would leave them permanently empty, since nothing would ever push to them. The team kept the real service names throughout (repo folders, resource names) rather than switching to the assignment's `service-a/service-b/service-c/` — that naming in the repo-shape diagram is illustrative placeholder text, not a literal requirement, and renaming an already-working system for no functional reason would only add risk. |
| State bucket | `devops-g1-iac-tfstate` (must be globally unique — needs a live check before use) |

**Required tags (all resources):**

| Key | Value |
|---|---|
| Project | `devops-mentorship` |
| Group | `group-1` |
| Owner | per-resource owner (service-a-owner / service-b-owner / service-c-owner / platform-owner) |
| Environment | `lab` |

---

## 6. Three predicted broken dependency edges

Predictions made *before* first apply, drawing on real failures already hit once in the console
build (same underlying causes are likely to resurface under Terraform, sometimes in a new form):

| # | Predicted break | User/system symptom | AWS evidence that would confirm it |
|---|---|---|---|
| 1 | Image built on Apple Silicon pushed without `--platform linux/amd64`, same as prior assignment Entry 1 | ECS service stuck at `runningCount: 0` indefinitely despite `ACTIVE` status | `aws ecs describe-services ... --query 'services[0].events[0:5]'` shows `CannotPullContainerError... platform` |
| 2 | Terraform-managed task role omits `ssmmessages:*` permissions needed for ECS Exec, since it's easy to define the execution role correctly and forget the task role is a separate resource | `aws ecs execute-command` fails at creation or connection time | `InvalidParameterException` on service create, or SSM session failure on connect |
| 3 | New Service Connect namespace/service-discovery names typo'd or mismatched between `modules/ecs-service` instances (e.g. Service B's Terraform variable for "the name Service C is discoverable as" doesn't match Service C's actual configured Service Connect port name) | Service B logs show DNS resolution failure calling Service C, even though both tasks are RUNNING and healthy | CloudWatch logs for Service B show `Name or service not known` / connection refused; `aws ecs describe-services` for Service C shows correct `serviceConnectConfiguration` that doesn't match what B was configured to call |

---

## 7. State-backend design

Separate bootstrap stack (its own, unversioned-by-workload Terraform config, applied once, outside
`infra/environments/lab`):

- S3 bucket, versioning enabled, default encryption **SSE-S3** (AWS-managed key — no extra IAM
  setup or per-request cost, unlike SSE-KMS, and there's no compliance requirement here that would
  justify a customer-managed key), all public access blocked (`aws s3api put-public-access-block`)
- **Tool: OpenTofu, pinned to ≥1.10** — the open-source Terraform fork, functionally equivalent
  for this assignment, with no licensing concerns. Version ≥1.10 supports native S3 state locking,
  so the team is not standing up a separate DynamoDB lock table — one less piece of infrastructure
  to build, tag, and explain during the demo.
- Workload state (`infra/environments/lab`) is stored under a distinct key in the same bucket,
  `lab/terraform.tfstate`, separate from the bootstrap stack's own state. The bootstrap stack
  itself is applied with local state for its one-time run — bootstrapping the very backend that
  would store its own state is a known chicken-and-egg problem, so the bootstrap config is kept
  intentionally minimal and out of the remote backend it creates.
- Backend bucket is never referenced inside the workload's own Terraform config as a *managed*
  resource — only as backend configuration — so a workload `destroy` structurally cannot touch it

---

## 8. Application-release ownership

Image pipeline (CodeBuild/CodePipeline, per-service, already exists and works for the console
system per prior assignment commits) builds and pushes SHA-tagged images to ECR. This assignment's
IaC does not build images and does not create new ECR repositories — it only *selects* which
already-pushed SHA is deployed, via a Terraform variable (e.g. `service_a_image_tag`) that feeds
the task definition's container image URI.

**Image path decision (resolves a real gap caught in review before first apply):** an earlier
draft of this design had Terraform *create* new ECR repos (`devops-g1-iac-ride-api`, etc.) while
this section assumed the *existing* pipeline would push into them. Those two statements
contradict each other — the existing CodeBuild/CodePipeline projects push to the existing repos
(`devops-g1-ride-api`, `devops-g1-matching-service`, `devops-g1-dispatch-service`), not to any
new `-iac-` repo, so a new repo would sit permanently empty and the first `terraform apply` would
fail with `CannotPullContainerError` before the environment ever came up.

Two ways to resolve this were considered:

- **(a) Chosen approach — reference the existing repos as read-only data sources.** Each service's
  Terraform module reads the existing repo's URI (`data "aws_ecr_repository" "..."`) rather than
  managing a new one. The existing pipelines keep working exactly as they already do; Terraform
  never creates, modifies, or deletes an ECR repository. This also keeps the "must not touch
  existing resources" boundary (§0) intact — the repos stay outside this build's blast radius
  entirely, satisfied by construction rather than by discipline.
- **(b) Rejected — greenfield-pure repos, with each pipeline (or a `crane`/`skopeo` retag step)
  repointed to also push into new `-iac-` repos.** More faithful to "everything greenfield," but
  doubles the image-push surface, adds a real chance of the two repo sets drifting out of sync,
  and adds failure modes to debug live during the demo for no functional benefit — the whole point
  of this assignment is proving the *infrastructure* is reproducible via IaC, not that image
  storage is duplicated.

```text
CI pipeline (per service, existing,     Terraform (IaC, this assignment)
unmodified by this assignment)
─────────────────────────────           ────────────────
build image
tag with Git SHA
push to existing ECR repo   ──────▶     data.aws_ecr_repository.service_x  (read-only lookup)
                                         var.service_x_image_tag = "<sha>"
                                                │
                                                ▼
                                         task definition references
                                         <existing-ecr-repo-uri>:<sha>
                                                │
                                                ▼
                                         terraform plan / apply
                                                │
                                                ▼
                                         ECS rolling deployment (new cluster)
```

Each service owner controls their own pipeline and SHA selection for their service; the Release
owner (rotating role, §Roles) is responsible for recording the plan summary, approval evidence, and
runtime proof for whichever release happens during their cycle.

---

## 8a. `modules/ecs-service` mandatory defaults and architecture-rules-as-code checks

**Module defaults (stated explicitly here, not just implied by "mirrors the console system"):**
every instantiation of `modules/ecs-service` — Service A, B, and C alike — defaults to:

- CloudWatch Logs enabled (`awslogs` driver, one log group per service)
- ECS Exec enabled (`enable_execute_command = true`)
- Deployment circuit breaker enabled, with automatic rollback on failure
- No override path that silently disables any of the four for a single service — these are
  hardcoded module defaults, not per-instance toggles, since the assignment requires all four
  unconditionally

**Architecture-rules-as-code — at least 6 automated checks, planned now, implemented alongside the
module (not deferred to Cycle 3):**

| # | Rule | Enforcement mechanism |
|---|---|---|
| 1 | A task must never receive a public IP | Variable validation on the module's `assign_public_ip` input — hardcoded to `false`, not exposed as a settable variable at all |
| 2 | Target group type must be `ip` | Hardcoded in `modules/alb`, not a variable |
| 3 | No application port open to `0.0.0.0/0` | `terraform plan` assertion / `checkov`-style policy check on every `aws_security_group_rule` resource |
| 4 | Image tag must never be `latest` | Variable validation (regex) on every `service_x_image_tag` input, rejecting the literal string `latest` and requiring a short-SHA-shaped value |
| 5 | Required tags present on every resource | `default_tags` block at the provider level, plus a policy check that fails if any resource's merged tag set is missing `Project`/`Group`/`Owner`/`Environment` |
| 6 | Deployed Region must be `us-east-1` | Provider `region` hardcoded, plus a `precondition` block checking `data.aws_region.current.name` before apply |

These six satisfy the assignment's "automatically reject or detect at least six" requirement and
directly support the Secure by Construction and Immutable Release badges.

---

## Roles and rotation

Per assignment requirement: "For three-person teams, rotate the platform and release roles between
cycles." Service ownership (A/B/C) stays fixed, matching the prior assignment and avoiding
re-learning a new service's internals mid-lab.

| Cycle | Platform owner | Release owner | Operator |
|---|---|---|---|
| 1 — Discover | Meron | Rigbe | Meron — the cycle's Platform owner drives the first apply, since they built the platform-layer modules and know the design's assumptions best |
| 2 — Teach | Nebyat | Meron | Rigbe — deliberately someone who did not drive Cycle 1, working from a clean checkout with independent AWS auth |
| 3 — Operate | Rigbe | Nebyat | Nebyat — gives every team member one turn as hands-on-keyboard operator across the three cycles (Meron in Cycle 1, Rigbe in Cycle 2, Nebyat here) |

Fixed for all cycles:

| Person | Service owned |
|---|---|
| Meron | Service A (ride-api) |
| Rigbe | Service B (matching-service) |
| Nebyat | Service C (dispatch-service) |

---

## How the team settled the remaining design questions

A handful of decisions weren't dictated by the assignment brief or the existing live system, so
the team split them by area of ownership and settled each one before this document was finalized:

Meron took the shared `modules/ecs-service` question, since the Cycle 1 Platform owner builds the
platform-layer modules first and is first to depend on it — Meron merges changes to that module,
with the other two service owners proposing changes through normal PRs as they instantiate it for
their own services.

Rigbe settled the ECR and resource naming question: keep the real service names (`ride-api`,
`matching-service`, `dispatch-service`) everywhere rather than renaming to the assignment's
`service-a/service-b/service-c`. That naming in the brief's repo-shape diagram reads as
illustrative placeholder text, not a literal requirement, and renaming an already-working system
for no functional reason would only add risk.

Nebyat owned the state-backend specifics: SSE-S3 encryption over SSE-KMS, since there's no
compliance requirement here that would justify a customer-managed key and no extra IAM plumbing;
and OpenTofu pinned to ≥1.10, chosen specifically because it supports native S3 state locking, so
the team isn't standing up a separate DynamoDB lock table.

Operator assignments were settled so every team member drives hands-on-keyboard exactly once
across the three cycles: Meron in Cycle 1, Rigbe in Cycle 2 (as required, since Cycle 2's operator
must not be whoever drove Cycle 1), and Nebyat in Cycle 3.

Before finalizing any of this, the team confirmed with each other that no one had already started
independent Terraform or OpenTofu work that these decisions would need to reconcile against — this
design reflects a genuinely empty starting point.

---

## Five architecture decision cards

### 1. Two Availability Zones

- **Risk reduced:** a single-AZ failure (rare but real — power, networking, or a zonal AWS outage)
  taking down the entire service, since Fargate tasks and the ALB would have nowhere else to run.
- **Trade-off accepted:** roughly double the baseline data-transfer and subnet-management overhead
  versus a single AZ; slightly more complex CIDR planning.
- **Well-Architected pillar:** Reliability.
- **Evidence:** `aws ecs describe-tasks` showing Service A's 2 tasks placed in different
  `availabilityZone` values; ALB target health checks passing in both AZs simultaneously.

### 2. Private Fargate tasks (no public IP)

- **Risk reduced:** direct internet exposure of application containers, which would let an
  attacker bypass the ALB and its listener rules entirely, hitting the app port straight from the
  internet.
- **Trade-off accepted:** tasks need either a NAT Gateway or VPC endpoints to reach AWS APIs
  (ECR, CloudWatch, SSM) — added design and (for NAT) cost complexity versus "just give it a public
  IP." We're accepting VPC endpoints' cost instead of NAT's, since our services need zero general
  internet access (verified by code review) and endpoints are more tightly scoped.
- **Well-Architected pillar:** Security.
- **Evidence:** `aws ecs describe-tasks` showing empty `publicIp` field in the task's network
  interface details; VPC Flow Logs (if enabled) showing no direct internet-sourced traffic to task
  ENIs.

### 3. Security-group references instead of IP allowlists

- **Risk reduced:** stale or overly broad firewall rules — a CIDR-based rule has to be manually
  updated if a service's IPs change (which happens constantly with Fargate, since tasks get new
  ENIs on every deployment), and a mistake there tends toward "allow too much" rather than "block
  legitimate traffic."
- **Trade-off accepted:** slightly less human-readable at a glance than a plain IP list; requires
  understanding that a security-group ID is a *dynamic group membership*, not a static address —
  a genuinely non-obvious AWS concept if you're new to it.
- **Well-Architected pillar:** Security.
- **Evidence:** `aws ec2 describe-security-group-rules` showing `ReferencedGroupInfo` (not
  `CidrIpv4`) as the source for every internal rule; a live test proving that when a task's IP
  changes after a redeploy, connectivity still works without any manual SG update.

### 4. Immutable image SHA (never `latest`)

- **Risk reduced:** non-reproducible deployments — with `latest`, "what's actually running" can
  silently change underneath you (someone pushes a new image, and every service referencing
  `latest` picks it up on next task launch, with no corresponding code change tracked anywhere).
  This also reduces rollback risk: a SHA-pinned deployment can always be rolled back to a known-
  good exact image.
- **Trade-off accepted:** one extra step in the release flow — the SHA has to be threaded through
  from the build pipeline into the Terraform variable/task definition explicitly, rather than
  "just deploy and it picks up whatever's newest."
- **Well-Architected pillar:** Operational Excellence.
- **Evidence:** `aws ecr describe-repositories` showing `imageTagMutability: IMMUTABLE`; a
  Terraform variable validation rejecting any image tag equal to the literal string `latest` or not
  matching a Git-SHA-shaped pattern (verified live: all three existing ECR repos already have
  `IMMUTABLE` set).

### 5. Remote, versioned, and locked state

- **Risk reduced:** two engineers applying Terraform at the same time and corrupting each other's
  changes (a real risk for this team specifically, since Cycle 2 explicitly requires a second
  engineer to operate from a separate, clean checkout); losing the state file entirely (which would
  make Terraform "forget" what it's managing, risking orphaned or duplicated resources).
- **Trade-off accepted:** more setup work up front (a whole separate bootstrap stack, as required)
  versus just using local state; a small amount of operational overhead any time state needs to be
  inspected (`terraform state list` against a remote backend instead of a local file).
- **Well-Architected pillar:** Operational Excellence (also touches Reliability, since state loss
  is a reliability risk to the *infrastructure*, not just the deployment process).
- **Evidence:** `aws s3api get-bucket-versioning` showing `Enabled`; `aws s3api
  get-public-access-block` showing all four block settings `true`; a deliberate test of two
  concurrent `terraform plan`/`apply` attempts showing the second one blocked/queued rather than
  silently racing the first.

---

## Gate 1 approval and before-first-apply checklist

**Status: approved by the instructor**, with two confirmations required before the first apply.
Instructor feedback, verbatim on the two open items:

> Service Connect namespace — verify the actual namespace constraint in AWS before applying
> rather than relying only on the assumption that the name must be unique across the account.
>
> Existing ECR repositories — document this explicitly as a shared external dependency: "New IaC
> environment reads images from existing shared ECR repositories and pipelines." Terraform must
> not modify or delete those repositories. Confirm that reproducibility means rebuilding the
> infrastructure from existing immutable images, not rebuilding every supporting delivery
> resource.

**Explicit shared-dependency statement (per instructor request):** this new IaC-managed
environment is *not* fully independent of the existing console-built environment — it reads
container images from the existing, shared ECR repositories (`devops-g1-ride-api`,
`devops-g1-matching-service`, `devops-g1-dispatch-service`) and their existing CI/CD pipelines.
Terraform in this assignment only ever reads those repositories via data source; it never
creates, modifies, or deletes them. "Destroy and rebuild" for this assignment means rebuilding
the *infrastructure* from already-existing, immutable, SHA-tagged images — not rebuilding the
image-delivery pipeline itself, which is out of this assignment's scope and stays owned by the
prior assignment's console-built pipelines.

### Before First Apply

- [x] Confirm the Service Connect namespace decision — **verified live**,
      2026-08-05: `aws servicediscovery list-namespaces` shows only `group1.internal`
      (`ns-dw5pfedkgu5jxtoc`) currently exists in this account/region. `aws servicediscovery
      get-namespace` confirms the namespace ARN is scoped
      `arn:aws:servicediscovery:us-east-1:827478161993:namespace/...` — i.e. uniqueness is
      enforced per account+region, not globally across AWS. `devops-g1-iac.internal` is a
      distinct name with no collision.
- [ ] Confirm the existing ECR repositories are read-only data sources (§8) — already resolved in
      this document; documented above as an explicit shared external dependency per instructor
      request
- [ ] Confirm no existing console resource is imported into state — enforced by
      `infra/tests/check-no-existing-resources.sh`, run against every saved plan's JSON output
      before every apply, not just once. Checks for the known existing resource identifiers from
      §0 (cluster name, ALB name, namespace name, ECR repo names, VPC id).
- [ ] Commit the OpenTofu/Terraform dependency lock file (`.terraform.lock.hcl`)
- [ ] Verify the selected OpenTofu version supports the planned S3 locking configuration (>= 1.10)
- [ ] Confirm all image SHA values referenced in `service_x_image_tag` variables already exist in
      the corresponding existing ECR repository before first apply
- [ ] Run `tofu fmt -check` and `tofu validate`
- [ ] Review the first plan for unexpected changes or deletes — zero tolerance for an unexplained
      replacement (per the assignment's own routine-plan-note rule)
- [ ] Confirm all resources target only `us-east-1`
- [ ] Cycle 1 operator: **Meron**. Cycle 1 reviewer: **Rigbe**.

**Keep the first apply small and reviewable** (instructor's explicit note) — every planned
resource, its dependency, and its effect on runtime behaviour must be explainable by the team,
not just the person who wrote it.
