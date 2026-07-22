# Group 1 — Demo Day Runbook (Zoom, Wed 22 July)

A start-to-finish script for the live demonstration. The system is **already deployed**; on demo
day we *prove* it works and *explain* the design. Each step is tagged **[EXPLAIN]** (show what's
already built) or **[LIVE]** (run it in front of the reviewer).

---

## 0. Facts everyone needs on screen

| Thing | Value |
|---|---|
| Region / Account | `us-east-1` / `827478161993` |
| Public URL (ALB) | `http://devops-g1-alb-308819154.us-east-1.elb.amazonaws.com` |
| Cluster | `devops-g1-cluster` |
| Namespace | `group1.internal` |
| Request chain | `ALB:80 → ride-api:3001 → matching:3002 → dispatch:3003 → callback ride-api:3001` |
| Endpoints | `/request-ride` (start) · `/find-driver` · `/assign-driver` · `/driver-assigned` (callback) · `/health` |

| Service | ECS service | Port | Count | SG | Public? |
|---|---|---|---|---|---|
| ride-api (P1) | `devops-g1-ride-api-svc` | 3001 | 2 | `sg-040f8062783e4fc92` | via ALB |
| matching (P2) | `devops-g1-matching-service-svc` | 3002 | 1 | `sg-04ce39108e5f243bf` | no |
| dispatch (P3) | `devops-g1-dispatch-service-svc` | 3003 | 1 | `sg-0ac76246a829107fc` | no |
| ALB SG (P2) | — | 80 | — | `sg-0edf8cf5f87caee80` | internet |

**Every terminal, run once:**
```bash
export AWS_REGION=us-east-1
export CL=devops-g1-cluster
export ALB=devops-g1-alb-308819154.us-east-1.elb.amazonaws.com
```

---

## 1. Roles & Zoom screen-share plan

| Person | Owns | Shares screen for |
|---|---|---|
| **P1** | ride-api (+ cluster, namespace) | Demo 1a, Demo 2 (drives), Demo 5 |
| **P2** | matching-service (+ ALB, target group) | Demo 1b, Demo 3 (drives) |
| **P3** *(you)* | dispatch-service (+ CodeConnections) | Demo 1c, Demo 6, Demo 7 |
| Team | — | Demo 4, Demo 8 |

**Handoff rule:** whoever is speaking shares. For team demos, one person drives the terminal while the others pull their own service's logs on their own screens.

---

## 2. The AWS services we deployed, and why (2-min [EXPLAIN] intro)

Whoever opens the demo says this while showing the architecture diagram:

| AWS service | Role in our system | Why |
|---|---|---|
| **IAM** | Identity + 4 role types | Nothing acts without an identity; least-privilege execution/task/build/pipeline roles |
| **ECR** | Private image registry | Fargate pulls immutable SHA-tagged images from here |
| **ECS on Fargate** | Serverless container runtime | Runs containers with no servers to manage |
| **ECS cluster** | Logical grouping | Namespaces our tasks/services (no compute itself) |
| **Task definition** | Container recipe | Image, CPU/mem, port, env, roles, health check |
| **ECS service** | Keeps N tasks alive | Replaces dead tasks; enables rolling deploys + rollback |
| **Cloud Map / Service Connect** | Service discovery by name | Services call `http://matching-service:3002`, not task IPs |
| **ALB + target group** | Public entry + load balancing | One public door; health-checks and spreads traffic to ride-api |
| **Security groups** | Stateful firewall | Enforce the traffic contract (least privilege between services) |
| **CloudWatch Logs** | Structured logs | `request_id` + `trace_id` follow one request across all 3 services |
| **CodeConnections** | GitHub ↔ AWS auth | Lets the pipeline read the repo |
| **CodePipeline** | Delivery orchestration | Source → Build → Deploy on every merge to `main` |
| **CodeBuild** | Build/test/push | Runs tests, builds image, tags SHA, pushes to ECR, emits `imagedefinitions.json` |
| **Container Insights** | Metrics | Cluster/task-level observability |

---

## 3. Demo 1 — Individual ownership (P1 → P2 → P3, 5 min each)

Mostly **[EXPLAIN]** with one **[LIVE]** beat. Each owner runs the identical 8 beats for their own
service. Below is **P3 / dispatch-service**; P1 and P2 mirror with their names/ports.

**Beat 1 — Image + SHA · [EXPLAIN]**
```bash
aws ecr describe-images --repository-name devops-g1-dispatch-service --region $AWS_REGION \
  --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].imageTags'
```
*Shows the current image tagged with a Git SHA (never `latest`).* → **Expect:** one SHA tag.

**Beat 2 — Task definition · [EXPLAIN]**
> Console: **AWS Console → ECS → Task definitions → `devops-g1-dispatch-service` → latest revision**
Point out: Fargate, awsvpc, named port 3003, `BIND_HOST=0.0.0.0`, execution + task roles, health check.

**Beat 3 — ECS service · [EXPLAIN]**
> Console: **AWS Console → ECS → Clusters → devops-g1-cluster → Services → devops-g1-dispatch-service-svc**
Point out: desired count 1, circuit breaker + rollback on, ECS Exec enabled.

**Beat 4 — Security group · [EXPLAIN]**
```bash
aws ec2 describe-security-groups --group-ids sg-0ac76246a829107fc --region $AWS_REGION \
  --query 'SecurityGroups[0].IpPermissions'
```
*Proves inbound is ONLY tcp/3003 from matching-service SG.* → **Expect:** exactly one rule.

**Beat 5 — CloudWatch log line · [EXPLAIN]**
```bash
aws logs tail /ecs/devops-g1-dispatch-service --since 10m --region $AWS_REGION
```
*Structured JSON logs with request_id/trace_id.* → **Expect:** health_check + startup lines.

**Beat 6 — Running version · [LIVE]** (your one live beat)
```bash
TASK=$(aws ecs list-tasks --cluster $CL --service-name devops-g1-dispatch-service-svc --region $AWS_REGION --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster $CL --task $TASK --container dispatch-service --interactive --command "/bin/sh" --region $AWS_REGION
# inside the container:
curl -s http://localhost:3003/health ; exit
```
*Opens a shell inside the live task and hits /health.* → **Expect:** `{"service":"dispatch-service","status":"healthy","version":"1.1.0",...}`.

**Beat 7 — Pipeline · [EXPLAIN]**
> Console: **AWS Console → CodePipeline → Pipelines → devops-g1-dispatch-service-pipeline**
Point out the three stages: Source → Build → Deploy.

**Beat 8 — SHA match · [EXPLAIN]** — the ECR SHA (beat 1) equals the task-def image tag = what's live.

> **Cross-question:** the reviewer asks each owner one question about a *teammate's* service. Be ready.

---

## 4. Demo 2 — End-to-end request · [LIVE] (P1 drives)

**Purpose:** one request, same correlation ID in all three services.

**P1 fires the request:**
```bash
curl -s -X POST http://$ALB/request-ride \
  -H 'X-Request-ID: DEMO-TRACE-001' -H 'Content-Type: application/json' -d '{"rider":"demo"}'
```
*Starts the chain through ride-api.* → **Expect:** a JSON response indicating a driver assigned.

**Each owner pulls the same ID from their log group (run in parallel):**
```bash
# P1
aws logs filter-log-events --log-group-name /ecs/devops-g1-ride-api --region $AWS_REGION --filter-pattern '"DEMO-TRACE-001"' --query 'events[].message'
# P2  -> /ecs/devops-g1-matching-service
# P3  -> /ecs/devops-g1-dispatch-service
```
→ **Expect:** the same `DEMO-TRACE-001` appears in **all three** log groups, including dispatch's callback to ride-api. **Verification = the ID present in all three.**

For each hop, state: destination · port · security group · Service Connect name · log evidence.

---

## 5. Demo 3 — Security boundaries · [LIVE] (P2 drives allow, P3 drives deny)

**Positive (must succeed):**
```bash
curl -i http://$ALB/health                                  # Internet → ALB (engineer machine)
```
Inside ride-api task (Exec): `curl -i --max-time 5 http://matching-service:3002/health`  → **A→B allowed**
Inside matching task (Exec): `curl -i --max-time 5 http://dispatch-service:3003/health`  → **B→C allowed**

**Negative (must be denied):**
Inside ride-api task (Exec): `curl -i --max-time 5 http://dispatch-service:3003/health`  → **A→C DENIED** (hangs/times out)
Internet → app ports directly (get a task public IP, curl :3001/:3002/:3003) → **all time out**

**Second evidence type (config):**
```bash
aws ec2 describe-security-groups --group-ids sg-0ac76246a829107fc --region $AWS_REGION \
  --query 'SecurityGroups[0].IpPermissions[].{port:FromPort,src:UserIdGroupPairs[0].GroupId}'
```
→ **Expect:** only `matching-sg → 3003`. **Verification = allow succeeds, deny times out, SG rule confirms why.** (Scored gate — caps at 75% if unproven.)

---

## 6. Demo 4 — Failure diagnosis · [LIVE] (team)

Reviewer injects one fault. Team narrates, in order: **symptom → hypothesis → evidence → root cause → repair → scar.** Probes:
```bash
aws ecs describe-services --cluster $CL --services <svc> --region $AWS_REGION --query 'services[0].events[:5]'
aws ecs describe-tasks --cluster $CL --tasks <task> --region $AWS_REGION --query 'tasks[0].stoppedReason'
aws elbv2 describe-target-health --target-group-arn <tg-arn> --region $AWS_REGION
```
Rules: no console takeover, evidence decides.

---

## 7. Demo 5 — Availability / kill a task · [LIVE] (P1 drives)

**Terminal A — continuous traffic:**
```bash
while true; do date; curl -s -o /dev/null -w "status=%{http_code} time=%{time_total}\n" http://$ALB/health; sleep 1; done
```
**Terminal B — stop one ride-api task:**
```bash
T=$(aws ecs list-tasks --cluster $CL --service-name devops-g1-ride-api-svc --region $AWS_REGION --query 'taskArns[0]' --output text)
aws ecs stop-task --cluster $CL --task $T --region $AWS_REGION
```
→ **Expect:** traffic barely blips (count 2 → second task absorbs it); ECS starts a replacement; target health transitions unhealthy→healthy. **Explain** why count 2 vs 1 matters.

---

## 8. Demo 6 — Hands-off delivery · [LIVE] (P3 leads, each owner shows theirs)

**Make a visible change and merge — no manual deploy after:**
```bash
git checkout main && git pull
git checkout -b demo/bump-version
# bump VERSION in services/dispatch-service/app.py (e.g. 1.1.0 -> 1.1.1)
git commit -am "Bump dispatch-service /health version for demo"
git push -u origin demo/bump-version
gh pr create --fill    # then review + merge on GitHub
```
**Then hand off the keyboard and narrate the pipeline:**
> Console: **AWS Console → CodePipeline → devops-g1-dispatch-service-pipeline** — watch Source → Build → Deploy auto-run.
**Verify live:**
```bash
aws codepipeline get-pipeline-state --name devops-g1-dispatch-service-pipeline --region $AWS_REGION \
  --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table
# after green, Exec in and curl /health -> shows 1.1.1
```
→ **Expect:** all stages Succeeded, new task-def revision, `/health` shows the new version. **Zero manual deploy commands.** (Backup: show a prior completed run in Execution history if the live build is slow.)

---

## 9. Demo 7 — Automatic rollback · [EXPLAIN] rehearsed (do [LIVE] only if time) (P3)

**Deploy a revision that fails its health check** (e.g., point the container health check at a wrong port), let it deploy, and show ECS auto-restore the known-good revision.
```bash
aws ecs describe-services --cluster $CL --services devops-g1-dispatch-service-svc --region $AWS_REGION \
  --query 'services[0].events[:8]'   # shows "circuit breaker" + rollback events
```
→ **Expect:** failed tasks, circuit-breaker event, service restored to the previous revision, `/health` healthy again. Record: failed revision #, circuit-breaker event, restored revision, user impact.
> **Prereq:** a known-good deployment must already be live. **Rehearse this tonight and keep the evidence** — too slow to first-attempt live.

---

## 10. Demo 8 — Best scar · [EXPLAIN] (team)

Present the **Service Connect DNS** scar in the arc **symptom → wrong hypothesis → evidence → actual cause → prevention**:
> "dispatch→ride-api callback failed with DNS `NameResolutionError` despite a correct SG rule. We first blamed the firewall. Evidence: logs showed name resolution failing, not a refused connection, and the task predated ride-api's namespace registration. Actual cause: Service Connect resolves a task's client endpoints **at launch time** — dispatch launched before ride-api joined `group1.internal`. Prevention: redeploy dependents after a late namespace join."

---

## 11. Close (30 sec)
"Every boundary proven both ways, one request traced across all three services, delivery fully hands-off, rollback automatic, every failure logged with root cause. Cleanup runs after grading — ALB first, default VPC never deleted."

---

## 12. Pre-demo checklist (run 30–45 min before the Zoom)
- [ ] `curl -s http://$ALB/health` → 200
- [ ] All 3 targets/tasks HEALTHY
- [ ] Session Manager plugin works for ECS Exec on each presenter's machine
- [ ] **Dry-run Demo 2** (callback chain green end-to-end)
- [ ] **Dry-run Demo 3** (A→C actually times out)
- [ ] **Gate 3B rehearsed**, evidence saved
- [ ] Tabs open: this runbook, scar log, Gate 1 doc, CodePipeline, CloudWatch
- [ ] Saboteur order agreed for Demo 4 (P1 → P2 → P3)
