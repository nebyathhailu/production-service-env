# ECS on Fargate — Phase 1 Plan & Team Task Breakdown

**Group number:** `1`
**Assigned AWS region:** `us-east-1`
**AWS account ID:** `827478161993` — confirm this matches what the rest of the team was given
**Resource naming prefix (mandatory on every resource):** `devops-g1-`

This document is the group's single source of truth for the ECS on Fargate lab. Fill in the
blanks together as a team before anyone touches the AWS Console. Once a value in the "Locked
Decisions" section is filled in, it does not change during implementation without the whole
team agreeing again — changing shared names/ports/roles mid-build is how these labs break.

---

## How to use this document ( read this first)

We couldn't meet as a group, so this document is written to be followed solo. Read it in this
order:

1. **Read Section 2 ("What our services actually do")** so you understand the app itself before
   touching AWS.
2. **Read Section 3 ("Locked Decisions") and fill in the group facts** (group number, region,
   account ID) if they aren't already filled in — message the group chat to confirm these before
   anyone builds anything, since every resource name depends on them.
3. **Claim your role in Section 4** — one of ride-api / matching-service / dispatch-service, plus
   its linked platform piece. First come, first served: message the group chat the moment you
   pick, so two people don't start the same one.
4. **Read Section 5 (Phase 1) fully before creating anything in AWS.** This is not optional — the
   instructor explicitly said no resources should exist before Gate 1, and the reasoning here is
   what you'll be asked to explain live in the demo.
5. **Check the "What Blocks What" table in Section 6** before starting your own Phase 2 work —
   some of your steps genuinely cannot start until a teammate finishes theirs.
6. **Do your own service's checklist** (Section 7, "Per-service-owner tasks") independently — this
   part does not require the group to be in sync minute-to-minute.
7. **Message the group chat once your per-service checkpoint passes** (task RUNNING, container
   HEALTHY, log visible, version visible, ECS Exec working) — this is the signal that unblocks
   Phase 3 for whoever's waiting on your service to exist.

If you get stuck, re-read the reasoning in Section 5 first — most confusion in this lab comes from
skipping the "why," not from missing a click.

---

## 2. What our services actually do (read this before touching AWS)

This is the same three-service pipeline from the local Docker Compose setup, renamed to a
ride-hailing theme. The architecture and behavior are identical — only the name and framing
changed.

**The flow:** `Client → Load Balancer → ride-api → matching-service → dispatch-service → callback
to ride-api`

- **ride-api** — the only publicly reachable service. Accepts a rider's request (`/request-ride`
  or similar), starts the chain, and later receives a callback once dispatch-service has finished
  processing. This is the "front door" of the whole system — everything else is internal-only.
- **matching-service** — receives the request from ride-api and is responsible for
  finding/validating a driver. Forwards the request on to dispatch-service. Never reachable from
  the public internet.
- **dispatch-service** — receives the request from matching-service, does the final
  assign/confirm step, and calls back to ride-api to report the outcome ("driver assigned").
  Never reachable from the public internet, and specifically never reachable directly from
  ride-api either (only through matching-service).

Every service exposes:
- `/health` — reports its own status (and, for ride-api/matching-service, whether the service it
  depends on is reachable)
- `/metrics` — Prometheus-format metrics (request count, error count, latency)
- Structured JSON logs with a `request_id` and `trace_id` so one request can be followed across
  all three services
- Lab-only failure endpoints (`/fail`, `/slow`, `/error`, `/dependency-fail`) used to deliberately
  break things during testing/demos

**What changes for AWS, and what stays the same:** the code itself does not need to change. What
changes is *where* it runs (Fargate task instead of a local Docker container) and *how* services
find each other (AWS Service Connect instead of Docker Compose's built-in DNS) and *what* sits in
front of it (an Application Load Balancer instead of Nginx). If your service already works
locally via `docker compose up`, hosting it on AWS is about correctly wiring the same container
into AWS's infrastructure — not rewriting application logic.

---

## 3. Locked Decisions (agree once, do not change while implementing)

| Decision | Value | Owner of the decision |
|---|---|---|
| Group number | `1` | Whole team |
| Assigned AWS region | `us-east-1` | Whole team |
| AWS account ID | `827478161993` (confirm with teammates) | Whole team |
| Resource naming prefix | `devops-g1-` | Whole team |
| Service Connect namespace | `group1.internal` | Platform owner |
| ride-api port | `3001` | Person 1 |
| matching-service port | `3002` | Person 2 |
| dispatch-service port | `3003` | Person 3 |
| ALB listener port | `80` | Platform owner |
| Health check path (all services) | `/health` | Whole team |
| Git branch protection on `main` | PRs required, 1+ approval, no direct pushes | Platform owner |
| Image tagging rule | Git commit SHA — **never `latest`** | Whole team |

**Required tags on every resource (no exceptions):**

| Key | Example |
|---|---|
| Project | `devops-mentorship` |
| Group | `group-<n>` |
| Owner | `ride-api-owner` / `matching-service-owner` / `dispatch-service-owner` / `platform-owner` |
| Environment | `lab` |

---

## 4. Pick Your Role

**First come, first served — claim one below by posting your name in the group chat, then write
it in this table (or in your own copy) so everyone can see it's taken.** Each role is one service
plus one fixed platform piece, for the entire lab — no rotation, no swapping mid-build.

| Role | Person (claim it) | Responsibilities |
|---|---|---|
| **Person 1 — ride-api owner** | `<claim this>` | Image, ECR repo, task definition, security group, ECS service, pipeline for ride-api — **plus platform: ECS cluster + Service Connect namespace** |
| **Person 2 — matching-service owner** | `<claim this>` | Image, ECR repo, task definition, security group, ECS service, pipeline for matching-service — **plus platform: ALB + target group** |
| **Person 3 — dispatch-service owner** | `<claim this>` | Image, ECR repo, task definition, security group, ECS service, pipeline for dispatch-service — **plus platform: CodeConnections setup** |

**Why the platform role is split this way (Option A — split by task, no rotation):** each piece
is assigned to the person whose own service work touches it earliest, so nobody blocks on a
handoff:

- **Person 1** owns the **ECS cluster** and the **Service Connect namespace** — needed early
  (Phase 2), so it's paired with the earliest-starting role.
- **Person 2** owns the **ALB** and the **target group** — needed once at least one service
  (ride-api) exists (Phase 3), so it's paired with a role that isn't blocking anyone in Phase 2.
- **Person 3** owns the **CodeConnections** setup — only needed in Phase 5, the last phase, so
  it's paired with the role that has the most slack before it's needed.

This assignment does not change during implementation. If a piece turns out to block someone
else's work, that's a sequencing issue to flag in the group chat (see Section 6, "What Blocks
What"), not a reason to reassign ownership mid-lab.

**Hard rule from the instructor:** you may advise another owner, but you may not operate their
console. If you help a teammate, you look and suggest — you do not take over their keyboard on
AWS resources that aren't yours.

---

## 5. Phase 1 — Draw the Graph (whole team, together, before touching AWS Console)

**Do not create any AWS resources until this section and Gate 1 are complete.**

### 5.1 Dependency graph

Draw this (on paper, in a shared doc, or a whiteboard tool) and keep the drawing as part of your
Gate 1 submission:

```
IAM identity
    |
Assigned Region
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
Service Connect namespace
    |
Target group
    |
Application Load Balancer
    |
DNS
```

Attached to this chain: CloudWatch Logs, CodeConnections, CodePipeline, CodeBuild, ECS deployment.

**Why this order matters (write-up for Gate 1):**

- **IAM identity** — nothing works without AWS first knowing who is asking. Absolute floor of the
  chain.
- **Assigned Region** — every resource lives inside exactly one region. Working in the wrong
  region silently produces resources nobody else on the team can see.
- **Default VPC + subnets in two AZs** — the two-AZ requirement isn't busywork: if one
  Availability Zone (effectively one physical data center) has an outage, the service keeps
  running in the other. This is the actual mechanism behind surviving a data-center failure.
- **Security groups** — must exist before a task launches, otherwise the task is either
  unreachable or dangerously open.
- **ECR repositories** — a container needs an image to run; nothing starts without one already
  pushed. Same role as Docker Hub in the local setup, just AWS's private version.
- **ECS cluster** — a logical grouping only; it does not run compute itself.
- **Task definitions** — the actual recipe (image, CPU/memory, port, permissions). Nothing runs
  without this existing first.
- **ECS services** — keeps N copies of a task definition running and replaces them if they die. A
  task definition alone is just a document; the service is what keeps something alive.
- **Service Connect namespace** — lets services find each other by name
  (`http://matching-service:3002`) instead of by ever-changing task IPs.
- **Target group + ALB + DNS** — the public door. The ALB needs a target group to know which
  tasks to send traffic to; DNS turns a human-readable address into the ALB's location.

**Senior-level takeaway:** almost every real outage in a system shaped like this comes from one
silently broken link in this chain, not the whole system failing at once — a forgotten security
group rule, or a task role missing one permission. That is the literal meaning of "the cloud is a
dependency graph."

### 5.2 Dependency questions (answer as a team)

| Question | Team answer |
|---|---|
| What must exist before a Fargate task can start? | The task definition, the ECR image it references (already pushed), the execution role (permission to pull that image and write logs), and the networking setup (VPC/subnet/security group) it will run inside. |
| What must exist before ECS can pull an image? | The ECR repository with the image already pushed and tagged, **and** the task's execution role must have ECR pull permissions attached. A common real mistake: the image is ready but the permission is forgotten, causing an "image pull failure." |
| What must exist before the ALB can route traffic? | A target group with at least one *healthy* registered target, and a listener rule connecting the ALB's port to that target group. |
| What depends on the named container port? | The task definition's port-mapping name is referenced directly by Service Connect. If the Service Connect config and the task definition's port-mapping name don't match exactly, internal service-to-service calls fail silently even though everything looks "running." |
| Which resources survive task replacement? | The ECS service, the cluster, the security groups, the ALB, the target group, and the ECR image all persist. Only the task itself (the literal running container instance) is disposable and gets replaced. |
| Which resources generate cost while idle? | Fargate tasks (billed the whole time they run, whether or not they serve traffic) and the ALB (billed hourly just for existing, plus per request). The ECS cluster and security groups themselves cost nothing directly. |

### 5.3 Failure predictions (pick three dependency edges)

| Broken edge | Expected user symptom | Expected AWS evidence |
|---|---|---|
| Example: ECS → ECR | Task never starts | Image pull error in ECS events |
| ECS task → ECR (wrong tag or missing pull permission) | Task never reaches RUNNING state | ECS console shows repeated STOPPED tasks; "stopped reason" mentions image pull failure |
| ALB target group → container port (wrong port number) | Requests to the ALB time out or return 502/503 | Target group shows targets as "unhealthy"; health check failing |
| ride-api → matching-service (Service Connect name mismatch) | Chain breaks after ride-api; request never completes | CloudWatch logs on ride-api show a connection/DNS failure trying to reach "matching-service" |

*(Revisit these predictions after deployment — note whether you were right. These are
hypotheses based on how ECS/ALB generally behave, not yet confirmed against this specific
account/cluster — treat the exact wording of "expected AWS evidence" as a best guess to verify,
not a guaranteed fact, until you've actually seen it happen once.)*

### 5.4 Traffic contracts

`Internet → ALB → ride-api → matching-service → dispatch-service`

No other application path should be permitted.

| Source | Destination | Port | Allowed? | Enforcement |
|---|---|---|---|---|
| Internet | ALB | 80 | Yes | ALB security group |
| Internet | ride-api | 3001 | No | ride-api security group |
| Internet | matching-service | 3002 | No | matching-service security group |
| Internet | dispatch-service | 3003 | No | dispatch-service security group |
| ALB | ride-api | 3001 | Yes | ALB SG → ride-api SG |
| ride-api | matching-service | 3002 | Yes | ride-api SG → matching-service SG |
| ride-api | dispatch-service | 3003 | No | No matching rule |
| matching-service | dispatch-service | 3003 | Yes | matching-service SG → dispatch-service SG |

Each communicating pair must agree, in writing, on: protocol, destination port, service name,
security-group reference, health endpoint, expected timeout. Fill in the specifics below:

| Pair | Protocol | Port | Service Connect name | SG reference | Health endpoint | Timeout |
|---|---|---|---|---|---|---|
| ALB → ride-api | HTTP | 3001 | ride-api | alb-sg → ride-api-sg | /health | 5s (matches `DOWNSTREAM_TIMEOUT` already used locally) |
| ride-api → matching-service | HTTP | 3002 | matching-service | ride-api-sg → matching-service-sg | /health | 5s |
| matching-service → dispatch-service | HTTP | 3003 | dispatch-service | matching-service-sg → dispatch-service-sg | /health | 5s |

**Why 5 seconds:** this matches the `DOWNSTREAM_TIMEOUT=5` your services already use locally
(`docker-compose.yml`/`.env.example`) — no reason to invent a new value for AWS when the app
code's own timeout constant already defines it. Keeping it consistent means the local and AWS
environments fail the same way under the same conditions, which makes the Phase 1 failure
predictions still valid once you're actually on AWS.

**Lab networking note:** tasks run in default public subnets with public IP assignment enabled
for outbound access. Public IP does not mean publicly permitted — security groups must still
block direct inbound access to the application services. Private subnets/NAT Gateways/VPC
endpoints are out of scope for this lab.

**Why `ride-api → dispatch-service` is explicitly denied (write-up for Gate 1):** the core
security idea here is that every service should only ever accept traffic from one specific
upstream neighbor — this mirrors exactly what the local setup already does with Docker's
`internal: true` network, just re-implemented with AWS security groups. The app's actual logic
never calls dispatch-service directly from ride-api (the flow is strictly A→B→C, never A→C). If
that connection were left open anyway, nothing would break today — but it would be a real
"least privilege" weakness: if ride-api were ever compromised, an open A→C path would hand an
attacker a direct route to dispatch-service the architecture never intended to expose. Blocking
it costs nothing and removes a path that should not exist.

### 5.5 Expected resource names (Group 1 — confirmed)

| Resource | Name |
|---|---|
| ECR — ride-api | `devops-g1-ride-api` |
| ECR — matching-service | `devops-g1-matching-service` |
| ECR — dispatch-service | `devops-g1-dispatch-service` |
| ECS cluster | `devops-g1-cluster` |
| Task definition — ride-api | `devops-g1-ride-api` (family name) |
| Task definition — matching-service | `devops-g1-matching-service` (family name) |
| Task definition — dispatch-service | `devops-g1-dispatch-service` (family name) |
| ECS service — ride-api | `devops-g1-ride-api-svc` |
| ECS service — matching-service | `devops-g1-matching-service-svc` |
| ECS service — dispatch-service | `devops-g1-dispatch-service-svc` |
| Security group — ALB | `devops-g1-alb-sg` |
| Security group — ride-api | `devops-g1-ride-api-sg` |
| Security group — matching-service | `devops-g1-matching-service-sg` |
| Security group — dispatch-service | `devops-g1-dispatch-service-sg` |
| Service Connect namespace | `group1.internal` |
| CloudWatch log group — ride-api | `/ecs/devops-g1-ride-api` |
| CloudWatch log group — matching-service | `/ecs/devops-g1-matching-service` |
| CloudWatch log group — dispatch-service | `/ecs/devops-g1-dispatch-service` |
| ALB | `devops-g1-alb` |
| Target group | `devops-g1-ride-api-tg` |
| CodeConnections connection | `devops-g1-github-connection` |
| CodeBuild project — ride-api | `devops-g1-ride-api-build` |
| CodeBuild project — matching-service | `devops-g1-matching-service-build` |
| CodeBuild project — dispatch-service | `devops-g1-dispatch-service-build` |
| CodePipeline — ride-api | `devops-g1-ride-api-pipeline` |
| CodePipeline — matching-service | `devops-g1-matching-service-pipeline` |
| CodePipeline — dispatch-service | `devops-g1-dispatch-service-pipeline` |

*(This list was incomplete in an earlier draft — the dependency graph mentions CloudWatch Logs,
CodeConnections, CodePipeline, and CodeBuild as attached to the chain, but the original names
table only covered ECR/cluster/security groups/namespace. Filled in above for completeness.)*

### Gate 1 submission checklist

- [ ] Dependency graph
- [ ] Three failure predictions
- [ ] Traffic contracts
- [ ] Resource ownership (Section 4 above)
- [ ] Expected resource names

**No resources should exist in AWS before Gate 1 is reviewed by the instructor.**

---

## 6. What Blocks What (read this before starting your own build)

Since we're working async, use this table to know exactly when you're clear to start each piece
of your own work, and what you're waiting on someone else for. If you hit a ✗, stop and check the
group chat for the signal instead of guessing or building around it.

| You want to do this... | You need this to exist/finish first... | Owned by |
|---|---|---|
| Build + push your own Docker image to ECR | Nothing — this can start immediately, independent of everyone else | You |
| Create your own ECR repository | Nothing — independent | You |
| Create your own task definition | Your own image already pushed to ECR (above) | You |
| Create your own ECS service | The **ECS cluster** must exist first | Person 1 |
| Register your service under Service Connect | The **Service Connect namespace** must exist, and your own ECS service must exist | Person 1 (namespace) + You (service) |
| Have ride-api registered with the public ALB | The **ALB and target group** must exist, and ride-api's own ECS service must be running | Person 2 (ALB/TG) + Person 1 (ride-api service) |
| Test ride-api → matching-service connectivity | Both services' ECS tasks running, both registered under Service Connect, both security groups created | Person 1 + Person 2 |
| Test matching-service → dispatch-service connectivity | Both services' ECS tasks running, both registered under Service Connect, both security groups created | Person 2 + Person 3 |
| Run Gate 2 (security proof) | All three services deployed and wired (the two rows above both pass) | Whole team |
| Set up your own CodeBuild/pipeline | The **CodeConnections** connection must exist and be authorized | Person 3 |
| Run Gate 3A (hands-off deploy) | Every person's own pipeline must be working, and CodeConnections must be set up | Whole team |

**Practical consequence of this table:** Person 1 should build first (ride-api + the ECS cluster
+ Service Connect namespace), since almost everyone else's next step depends on the cluster and
namespace existing. Persons 2 and 3 can build and push their own images and write their own task
definitions in parallel while waiting — the only thing that's actually blocked is *creating the
ECS service* and *wiring Service Connect*, not the earlier Docker/ECR steps.

---

## 7. Phase 2 — Host Each Service

**Progress log (Person 1 / ride-api, real resources created so far):**
- ✅ ECS cluster `devops-g1-cluster` (Fargate, Container Insights on)
- ✅ Service Connect namespace `group1.internal`
- ✅ ECR repo `devops-g1-ride-api` (immutable tags) + image pushed, tagged `8a9d256`
- ✅ Execution role `devops-g1-ecs-execution-role` (AmazonECSTaskExecutionRolePolicy attached)
- ✅ CloudWatch log group `/ecs/devops-g1-ride-api`
- ✅ Task definition `devops-g1-ride-api:1` (0.25 vCPU / 0.5 GB, named port mapping `ride-api`,
  no task role — ride-api makes no AWS API calls itself, only plain HTTP to matching-service)
- ✅ Security group `sg-040f8062783e4fc92` (`devops-g1-ride-api-sg`) — **created with zero inbound
  rules on purpose.** Needs one inbound rule added later: allow port 3001 **from the ALB's
  security group** once Person 2 creates it. Do not open this to `0.0.0.0/0` or a raw IP range —
  it must reference the ALB SG by ID, per the traffic-contract requirement in Section 5.4.

### Per-service-owner tasks (Person 1 / 2 / 3 — each does this for their own service only)

- [ ] Create your ECR repository (`devops-g<n>-<your-service>`) — one per person, per service, not
      shared. Use `--image-tag-mutability IMMUTABLE` so a tag can never be silently overwritten.
- [ ] Build your Docker image **explicitly for `linux/amd64`** — Fargate only runs amd64, and a
      plain `docker build` on an Apple Silicon Mac produces an arm64 image by default, which
      **will fail to deploy** with `CannotPullContainerError: image Manifest does not contain
      descriptor matching platform 'linux/amd64'` (hit and confirmed by Person 1 — this is a real
      scar-log entry, not a hypothetical). Use:
      ```bash
      docker buildx build --platform linux/amd64 \
        -t <account>.dkr.ecr.<region>.amazonaws.com/devops-g<n>-<your-service>:<git-sha> \
        -f services/<your-service>/Dockerfile \
        --push .
      ```
      (`--push` builds and pushes in one step for a non-native platform — `docker build` alone
      cannot load a foreign-platform image into your local Docker afterward, so build-then-push as
      two separate commands does not work the same way here.)
- [ ] Tag it with the **Git commit SHA** — never `latest`
- [ ] Confirm your service exposes its version via `/health`, `/version`, startup logs, or the
      application response, e.g.:
      ```json
      { "service": "ride-api", "version": "a81f23c", "status": "ok" }
      ```
- [ ] Before registering your task definition, answer for your own service:
  - [ ] Does the application listen on `0.0.0.0`?
  - [ ] Which port does it listen on?
  - [ ] Which process runs as PID 1?
  - [ ] How does the container shut down?
  - [ ] What proves it is healthy?
  - [ ] Why is the port mapping named?
  - [ ] Does the application need a task role?
- [ ] Write your task definition: Fargate, `awsvpc` network mode, immutable ECR image, chosen +
      justified CPU/memory, **named** port mapping, CloudWatch Logs, health check, execution role
      (image pull + logging), task role if needed
- [ ] Create your ECS service:
  - Fargate launch type
  - Two default subnets in different Availability Zones
  - Your dedicated security group
  - Public IP enabled (lab requirement)
  - Deployment circuit breaker enabled
  - Automatic rollback enabled
  - ECS Exec enabled (`enableExecuteCommand`)
  - Desired count: **2 for ride-api**, **1 for matching-service**, **1 for dispatch-service**
- [ ] Verify ECS Exec works on your service:
  ```
  aws ecs execute-command \
    --cluster devops-g<n>-cluster \
    --task <task-id> \
    --container <your-service-name> \
    --interactive \
    --command "/bin/sh"
  ```
- [ ] Confirm `curl`/`wget` is available inside your image (needed for ECS Exec connectivity
      tests) — add it to the Dockerfile if missing, do not install it manually into a running task
- [ ] Hit your per-service checkpoint and be ready to demo it:
  - [ ] Task state: RUNNING
  - [ ] Container health: HEALTHY
  - [ ] CloudWatch: application log visible
  - [ ] Version: current Git SHA visible
  - [ ] ECS Exec: command succeeds

### Platform-owner tasks (whoever holds the role for this phase)

- [ ] Create the ECS cluster (`devops-g<n>-cluster`)
- [ ] Confirm default VPC and subnets in at least two Availability Zones are available for use
- [ ] Prepare (but do not finish wiring) the Service Connect namespace — full wiring happens in
      Phase 3
- [ ] Prepare (but do not finish wiring) the ALB and target group — full wiring happens in Phase 3

---

## 8. Phase 3 — Wire the System (platform owner leads, service owners coordinate)

- [ ] Create Service Connect namespace `group<n>.internal`
- [ ] Register all three services under Service Connect using the exact names agreed in Section 0
- [ ] Confirm application code calls downstream services by **Service Connect name**, never by
      task IP:
      - ride-api → `http://matching-service:<port>`
      - matching-service → `http://dispatch-service:<port>`
- [ ] Verify port-mapping names match the Service Connect configuration
- [ ] Verify destination security groups allow the correct port
- [ ] Verify correlation/request IDs are forwarded between services (you already do this with
      `X-Request-ID` — confirm it survives the AWS hop too)
- [ ] Create the four security groups (Section 2.5), each referencing the *previous* group in the
      chain, not IP ranges
- [ ] Create the ALB: internet-facing, at least 2 AZs, HTTP listener on port 80, target group type
      `ip`, **only ride-api registered**, health-check path `/health`
- [ ] Confirm matching-service and dispatch-service have **no public target groups**

### Gate 2 — Runtime and Security Proof

Positive tests (must succeed):

| Test | Where executed |
|---|---|
| Internet → ALB | Engineer machine |
| ALB → ride-api | Through public request |
| ride-api → matching-service | Inside ride-api task (ECS Exec) |
| matching-service → dispatch-service | Inside matching-service task (ECS Exec) |

Negative tests (must fail/deny):

| Test | Where executed |
|---|---|
| Internet → ride-api app port | Engineer machine |
| Internet → matching-service app port | Engineer machine |
| Internet → dispatch-service app port | Engineer machine |
| ride-api → dispatch-service | Inside ride-api task (ECS Exec) |

Example internal test commands:
```
curl -i --max-time 5 http://matching-service:<port>/health
curl -i --max-time 5 http://dispatch-service:<port>/health
```

Use at least two evidence types: ECS Exec command output, security-group rules, CloudWatch Logs,
ECS events, VPC Flow Logs (if configured), Reachability Analyzer (if applicable).

**Gate 2 passes only when both configuration and runtime behavior are proven — not one or the
other.**

---

## 9. Phase 4 — Prove It Operates (whole team, together)

- [ ] Trace one real request end to end: DNS → ALB listener → target group → ride-api → Service
      Connect → matching-service → Service Connect → dispatch-service. For every hop, record:
      resource permitting it, destination port, evidence it occurred, expected failure symptom if
      it broke. Compare against your Phase 1 predictions — were you right?

### Sabotage round

Each service owner **secretly** introduces one failure into their own service (pick one, do not
tell the team which):

- Wrong health-check path
- Wrong container port
- Missing Service Connect name
- Blocking security-group rule
- Application bound to `localhost`
- Nonexistent image tag
- Insufficient memory
- Public IP disabled
- Incorrect execution role

Rules: no console takeover, no revealing the injected fault, no repair before evidence is
gathered. Investigators use ECS service events, stopped-task reasons, ALB target health,
CloudWatch Logs, task-definition revisions, security-group rules.

**Every sabotage becomes a scar-log entry** (see template in Section 12).

**How to run this round as a team (agree on this logistics detail in advance):** pick a fixed
order (e.g., Person 1's service is investigated first, then Person 2's, then Person 3's) so only
one saboteur is "live" at a time — otherwise multiple simultaneous faults make it impossible to
tell which evidence belongs to which failure. The saboteur stays silent and only confirms
correctness once the rest of the team has stated a root cause out loud, matching the instructor's
explicit rule: "team diagnoses aloud, evidence decides."

### Kill-a-task test

```
while true; do
  date
  curl -s -o /dev/null \
    -w "status=%{http_code} time=%{time_total}\n" \
    http://<alb-dns-name>/
  sleep 1
done
```

While this runs, stop one ride-api task and record:

- [ ] Failed requests
- [ ] Non-200 responses
- [ ] Slow requests
- [ ] Replacement start time
- [ ] Target registration
- [ ] Target health transition
- [ ] Recovery time

Then answer as a team (predicted answers below — confirm or correct after running the actual
test):
1. **Why did ECS replace the task?** Because the ECS service's desired count is a standing
   instruction ("keep N of these running at all times"), not a one-time action. The moment a task
   stops, ECS notices the running count no longer matches the desired count and starts a
   replacement automatically — this is the entire reason an ECS *service* exists on top of a task
   definition.
2. **How did the ALB avoid an unhealthy target?** The target group's own health check keeps
   polling `/health` independently of ECS. The instant the stopped task fails to respond, the ALB
   marks that target unhealthy and stops sending it new requests — traffic shifts to the
   remaining healthy target(s) before the replacement task even finishes starting, which is why
   desired count 2 should show far fewer failed requests than desired count 1.
3. **Did Service Connect require reconfiguration?** No — Service Connect resolves the service
   name (`ride-api`) to whichever healthy tasks currently exist, not to a fixed task IP. A new
   task registers itself under the same name automatically; nothing about the DNS/service-name
   config needs to change when a task is replaced.
4. **What changes if desired count is 1 instead of 2?** With desired count 2, there's always a
   second task already running and healthy to absorb traffic the instant the first one dies —
   likely close to zero failed requests. With desired count 1, there is no standby: every request
   arriving during the gap between "task stopped" and "replacement task passes its health check"
   will fail or time out. This is exactly why ride-api (the only publicly reachable service) is
   set to desired count 2 while matching-service/dispatch-service are set to 1 — the assignment
   is deliberately testing whether you understand *why* that asymmetry exists, not just copying
   the numbers.

---

## 10. Phase 5 — Ship It Hands-Off

### Platform-owner tasks

- [ ] Create and authorize one CodeConnections connection for the group repository
- [ ] Confirm: connection status is `available`, correct repository authorized, source branch is
      `main`, all three service pipelines can reuse the same connection
- [ ] Enable branch protection on `main`: pull requests required, at least one approval required,
      direct pushes blocked, required checks must pass where available

### Per-service-owner tasks

- [ ] Create your own CodeBuild project using `buildspecs/<your-service>.yml`
- [ ] Your CodeBuild must: use the correct buildspec, run tests where present (otherwise run a
      meaningful build/config validation), build the correct image, tag with commit SHA, push to
      your correct ECR repository, produce `imagedefinitions.json`
- [ ] Enable **privileged mode** on your CodeBuild project (required for Docker builds)
- [ ] Confirm your `imagedefinitions.json` container name matches your ECS task-definition
      container name **exactly**:
      ```json
      [{ "name": "matching-service",
         "imageUri": "<account>.dkr.ecr.<region>.amazonaws.com/devops-g<n>-matching-service:<sha>" }]
      ```
- [ ] Set up IAM roles correctly and minimally:
  - CodeBuild role: read source, write logs, authenticate to ECR, push images
  - CodePipeline role: invoke CodeBuild, read artifacts, deploy to ECS
  - ECS execution role: pull images, send logs
  - ECS task role: runtime permissions, ECS Exec support
  - **Do not grant unrestricted `iam:PassRole`** — scope it to the exact ECS task/execution
    roles used by the group

### Gate 3A — Hands-off deployment

Merge a visible service version change into `main`. After the merge, **no manual deployment
action is allowed.**

| Stage | Required evidence |
|---|---|
| Pull request | Reviewed and approved |
| Commit | Git SHA recorded |
| Source stage | Triggered automatically |
| CodeBuild | Correct service built |
| ECR | SHA-tagged image pushed |
| Build artifact | Correct `imagedefinitions.json` |
| ECS deploy | New revision deployed |
| Runtime | New SHA visible through ALB |

### Gate 3B — Automatic rollback

Deploy a revision that deliberately fails its health check. Record:

- [ ] Failed task-definition revision
- [ ] ECS and ALB failure evidence
- [ ] Circuit-breaker event
- [ ] Restored revision
- [ ] Recovery confirmation
- [ ] User-visible impact

**The service must have a known-good completed deployment before testing rollback.**

---

## 11. Phase 6 — Handoff and Cleanup (whole team)

### Cost sweep

| Resource | Bills while idle? | Cleanup required? |
|---|---|---|
| Fargate tasks | Yes | Yes |
| Application Load Balancer | Yes | Yes |
| CodeBuild | Per build | No persistent compute |
| CodePipeline | Possible pipeline cost | As instructed |
| ECR images | Storage | As instructed |
| CloudWatch Logs | Ingestion and storage | As instructed |
| Container Insights | Metrics usage | As instructed |
| Security groups | No direct cost | Yes |
| ECS cluster | No direct cost | Yes |
| Default VPC | No direct cost | **Never delete** |

**Most expensive resource likely to be forgotten:** the **Application Load Balancer**. Fargate
tasks stop billing the moment you scale a service to 0 or delete it, but the ALB bills a flat
hourly rate for existing at all, *plus* a per-processed-byte charge, for as long as it exists —
whether or not anyone is sending it traffic. A team that tears down its ECS services but forgets
the ALB itself will keep paying for it silently. This is exactly why the cleanup order below puts
the ALB high on the list, ahead of things like security groups that cost nothing to leave behind
temporarily.

### Cleanup order (do not skip steps or go out of order)

```
Pipelines
  -> ECS services
  -> Application Load Balancer
  -> Target groups
  -> ECS cluster
  -> Custom security groups
  -> CloudWatch log groups
  -> ECR repositories (only if instructed)
```

**Never delete:** default VPC, default subnets, default route table, default Internet Gateway,
shared Route 53 zones, another group's resources.

- [ ] Confirm no unintended billable resources remain

---

## 12. Scar Log (fill in one entry per meaningful failure — required, not optional)

**A clean/empty scar log is not automatically a strong result** — the instructor treats a lack
of documented failures as a red flag, not a sign of a smooth build. Log every real failure,
including the small dumb ones.

### Entry 1 — Person 1 / ride-api — image failed to pull on Fargate

| Field | Entry |
|---|---|
| Symptom | `aws ecs create-service` succeeded and the service showed `ACTIVE`, but `runningCount` stayed at `0` indefinitely. Desired count was 2, actual running count never moved off 0 after several minutes. |
| First hypothesis | Assumed it was a permissions problem — that the execution role couldn't pull from ECR, or was missing a permission. |
| Evidence | `aws ecs describe-services ... --query 'services[0].events[0:5]'` showed the real message directly: `CannotPullContainerError: pull image manifest has been retried 7 time(s): image Manifest does not contain descriptor matching platform 'linux/amd64'.` This ruled out the permissions hypothesis immediately — a permissions failure gives a different, distinct error (access denied), not a missing-platform error. |
| Actual cause | The image was built locally with a plain `docker build` on an Apple Silicon (arm64) Mac. Docker defaults to building for the host machine's own architecture, so the pushed image only had an arm64 manifest. AWS Fargate only runs `linux/amd64` images (ARM-based Fargate exists but is a separate, explicitly-opted-into configuration we did not use) — so ECS could see the image in ECR, but had no compatible manifest to actually run. |
| Repair | Rebuilt the image explicitly targeting the correct platform: `docker buildx build --platform linux/amd64 -t <ecr-uri>:<tag>-amd64 -f services/ride-api/Dockerfile --push .` — verified the pushed manifest actually contained `Platform: linux/amd64` via `docker buildx imagetools inspect` before wiring it into a new task definition revision, then force-deployed the ECS service onto that corrected revision. |
| Prevention | Always build container images destined for Fargate with an explicit `--platform linux/amd64` flag when developing on Apple Silicon hardware — never rely on the platform-less default `docker build`, since it silently succeeds locally (your own Mac can run the arm64 image fine) and only fails once it reaches AWS. Documented this exact command in Section 7 of this plan so Person 2 and Person 3 don't repeat it. |

### Entry 2 — Person 1 / ride-api — ECS Exec required a task role, not just an execution role

| Field | Entry |
|---|---|
| Symptom | `aws ecs create-service ... --enable-execute-command` failed immediately with `InvalidParameterException: The service couldn't be created because a valid taskRoleArn is not being used.` |
| First hypothesis | Assumed the task definition simply didn't need a task role at all, since ride-api's own application code makes no direct AWS API calls (no S3, no DynamoDB, no Secrets Manager) — only plain HTTP calls to matching-service. |
| Evidence | The error was explicit and specific about needing a `taskRoleArn`, not an execution-role problem — and AWS's own ECS Exec documentation confirms the SSM session channel used by `execute-command` requires permissions (`ssmmessages:CreateControlChannel`, etc.) that must live on the task role, separate from the execution role's image-pull/logging permissions. |
| Actual cause | Conflated "does the application need AWS permissions" with "does the task need AWS permissions." ECS Exec itself is a feature the *task* uses (to let AWS's Session Manager attach a shell into the running container), independent of whether the application code inside ever calls an AWS API directly. |
| Repair | Created a dedicated task role (`devops-g1-ride-api-task-role`) with an inline policy granting exactly the four `ssmmessages:*` actions ECS Exec needs, attached it as `taskRoleArn` in the task definition, registered a new revision, and re-created the service successfully. |
| Prevention | When a task definition enables `enableExecuteCommand`, always create a minimal task role with the SSM messaging permissions up front, even if the application itself needs no other AWS access — don't assume "no task role" just because the app code doesn't call AWS APIs. |

---

## 13. Live Demo Prep Checklist (Wednesday, July 22)

- [ ] Demo 1 — each owner, 5 min: ECR + current image SHA, task definition, ECS service, security
      group, CloudWatch log line, ECS Exec access, delivery pipeline, running version. **Be ready
      to answer one question about a teammate's service** — knowledge must not be concentrated in
      one person.
- [ ] Demo 2 — trace one live request end to end, as a team, same correlation ID visible in all
      three services
- [ ] Demo 3 — prove all security boundaries live (allow and deny cases)
- [ ] Demo 4 — live failure diagnosis of an instructor-injected fault (symptom → hypothesis →
      evidence → root cause → repair → scar log entry)
- [ ] Demo 5 — live availability test (stop a task while continuous traffic runs)
- [ ] Demo 6 — live hands-off deployment (merge to `main`, zero manual steps after)
- [ ] Demo 7 — live rollback demonstration
- [ ] Demo 8 — present your team's single best scar-log entry (clearest learning, not necessarily
      the most complex failure)

---

## 14. Scoring Awareness (know these caps before you plan)

| Condition | Maximum score |
|---|---|
| One person controls most of the implementation | 70% |
| Gate 2 security boundaries not proven | 75% |
| No scar log or weak evidence | 70% |
| No hands-off deployment | 80% |
| Manual intervention required after merge | 85% |
| No rollback demonstration | 90% |
| Billable resources left running after cleanup deadline | 80% |
| Another group's resources modified or deleted | Review required |

A working application alone is not enough — the group must demonstrate ownership, security,
evidence, recovery, and delivery.
