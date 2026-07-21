# Group 1 — Live Demo Runbook (Wed 22 July)

**Region:** us-east-1 · **Account:** 827478161993 · **ALB:** `devops-g1-alb-308819154.us-east-1.elb.amazonaws.com`

**Roles**
- **P1 — ride-api owner** (+ platform: ECS cluster, Service Connect namespace) — the front door, desired count 2
- **P2 — matching-service owner** (+ platform: ALB, target group)
- **P3 — dispatch-service owner** (+ platform: CodeConnections) — *(you, Nebyat)*

**Golden rules for the room**
- Lead with **evidence** (a log line, an SG rule, command output), never "it works."
- Every person must be able to answer a question about **another** person's service (ownership cap = 70% otherwise).
- No console takeover of another owner's resources. No touching other groups' resources.

**Request chain (memorise this):**
`Client → ALB:80 → ride-api:3001 → matching:3002 → dispatch:3003 → callback ride-api:3001`
Endpoints: `POST /request-ride` (start) · `/find-driver` · `/assign-driver` · `POST /driver-assigned` (callback).

**One terminal, set once:**
```bash
export ALB=devops-g1-alb-308819154.us-east-1.elb.amazonaws.com
export AWS_REGION=us-east-1
export CL=devops-g1-cluster
```

---

## Pre-flight (30 min before, off-screen)
- [ ] All 3 services `RUNNING`/`HEALTHY`, ALB target healthy: `aws elbv2 describe-target-health --target-group-arn arn:aws:elasticloadbalancing:us-east-1:827478161993:targetgroup/devops-g1-ride-api-tg/93f114ed1201b587 --region us-east-1 --query 'TargetHealthDescriptions[].TargetHealth.State'`
- [ ] `curl -s http://$ALB/health` returns 200
- [ ] Session Manager plugin working for ECS Exec on all three machines
- [ ] Scar log + Gate 1 doc open in tabs
- [ ] Decide the Demo 4 saboteur order (P1 → P2 → P3) and Demo 8 scar (recommend P3's Service Connect DNS scar)

---

## Demo 1 — Individual ownership (5 min each, P1 → P2 → P3)

Each owner runs the **same 8-beat script** for their own service. Below is **P3 / dispatch-service**; P1 and P2 mirror it with their names/ports.

| # | Say | Do / show on screen |
|---|-----|---------------------|
| 1 | "dispatch-service, my image is tagged with the Git SHA — never `latest`." | `aws ecr describe-images --repository-name devops-g1-dispatch-service --region us-east-1 --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].imageTags'` |
| 2 | "Here's the task definition — Fargate, awsvpc, named port 3003, BIND_HOST 0.0.0.0, exec + task roles." | ECS console → Task definitions → `devops-g1-dispatch-service` latest revision |
| 3 | "The service keeps 1 task alive, circuit breaker + rollback + ECS Exec on." | ECS console → `devops-g1-dispatch-service-svc` |
| 4 | "Its security group allows inbound 3003 **only** from matching-service." | `aws ec2 describe-security-groups --group-ids sg-0ac76246a829107fc --region us-east-1 --query 'SecurityGroups[0].IpPermissions'` |
| 5 | "Structured JSON logs with request_id + trace_id." | `aws logs tail /ecs/devops-g1-dispatch-service --since 5m --region us-east-1` |
| 6 | "The running version is provable via /health over ECS Exec." | Exec in (below), `curl -s http://localhost:3003/health` → shows `"version":"1.1.0"` |
| 7 | "Delivery is a 3-stage pipeline: Source → Build → Deploy." | CodePipeline → `devops-g1-dispatch-service-pipeline` |
| 8 | "And this SHA matches what's live in ECS." | point out ECR SHA == task-def image tag |

**ECS Exec (beat 6):**
```bash
TASK=$(aws ecs list-tasks --cluster $CL --service-name devops-g1-dispatch-service-svc --region $AWS_REGION --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster $CL --task $TASK --container dispatch-service --interactive --command "/bin/sh" --region $AWS_REGION
# inside: curl -s http://localhost:3003/health ; exit
```

> **Instructor cross-question:** each owner must field one question about a *teammate's* service. Rehearse: P3 should be able to explain P1's desired-count-2 and P2's ALB target group.

---

## Demo 2 — End-to-end request (team; P1 drives)

**Goal:** one request, same correlation ID visible in all three services.

| Say (P1) | Do / show |
|---|---|
| "I fire one ride request at the ALB with a known request ID." | `curl -s -X POST http://$ALB/request-ride -H 'X-Request-ID: DEMO-TRACE-001' -H 'Content-Type: application/json' -d '{"rider":"demo"}'` |
| "Same ID appears in ride-api…" | `aws logs filter-log-events --log-group-name /ecs/devops-g1-ride-api --region us-east-1 --filter-pattern '"DEMO-TRACE-001"' --query 'events[].message'` |
| "…in matching-service…" (P2) | same command, log group `/ecs/devops-g1-matching-service` |
| "…and in dispatch-service, including the callback to ride-api." (P3) | same command, log group `/ecs/devops-g1-dispatch-service` |

For each hop state: **destination · port · security group · Service Connect name · log evidence · failure symptom if broken.**

---

## Demo 3 — Security boundaries (team; P2 drives allow, P3 drives deny)


### Part 1 — the "allow" case

```bash
curl -i http://$ALB/health
```

Expected: `HTTP/1.1 200 OK` followed by the JSON health response.

### Part 2 — the "deny" case

**Step 1 — get a running ride-api task ID:**

```bash
TASK=$(aws ecs list-tasks --cluster devops-g1-cluster --service-name devops-g1-ride-api-svc --profile devops-lab --region us-east-1 --query 'taskArns[0]' --output text)
echo $TASK
```

**Step 2 — open an interactive shell inside ride-api:**

```bash
aws ecs execute-command --cluster devops-g1-cluster --task $TASK --container ride-api --interactive --command "/bin/sh" --profile devops-lab --region us-east-1
```

**Step 3 — once you're inside the shell** (you'll see a `#` prompt), try to reach dispatch-service directly:

```bash
curl -i --max-time 5 http://dispatch-service:3003/health
```

Expected: it hangs for 5 seconds, then:

```
curl: (28) Operation timed out after 5000 milliseconds with 0 bytes received
```

**Step 4 — show the security group rule that explains why**, back in your normal terminal (not inside the container):

```bash
aws ec2 describe-security-groups --group-ids sg-0ac76246a829107fc --profile devops-lab --region us-east-1 --query 'SecurityGroups[0].IpPermissions[].{port:FromPort,src:UserIdGroupPairs[*].GroupId}'
```

Expected: shows port 3003 only allowing inbound from matching-service's security group ID — ride-api's SG isn't in that list, which is exactly why the curl above timed out.

---

## Demo 4 — Failure diagnosis (team; instructor injects fault)

Follow the discipline out loud, in order — **evidence decides**:
1. **Symptom** — what the user sees (e.g., 502 at ALB, or chain stalls).
2. **Hypothesis** — first suspicion.
3. **Evidence** — ECS events, stopped-task reason, ALB target health, CloudWatch, task-def revisions, SG rules.
4. **Root cause** — name the broken edge.
5. **Repair** — what you'll change.
6. **Scar log** — record it.

Handy probes:
```bash
aws ecs describe-services --cluster $CL --services <svc> --region us-east-1 --query 'services[0].events[:5]'
aws elbv2 describe-target-health --target-group-arn <tg-arn> --region us-east-1
```

---

## Demo 5 — Availability / kill a task (team; P1 drives — ride-api is count 2)

**Terminal A (continuous traffic):**
```bash
while true; do date; curl -s -o /dev/null -w "status=%{http_code} time=%{time_total}\n" http://$ALB/health; sleep 1; done
```
**Terminal B (kill one ride-api task):**
```bash
T=$(aws ecs list-tasks --cluster $CL --service-name devops-g1-ride-api-svc --region us-east-1 --query 'taskArns[0]' --output text)
aws ecs stop-task --cluster $CL --task $T --region us-east-1
```
Record: failed/non-200/slow requests, replacement start, target registration, health transition, recovery time.
**Explain:** with desired count **2** traffic barely blips (second task absorbs it); with **1** there'd be a gap. That's *why* ride-api is 2 and matching/dispatch are 1.

---

## Demo 6 — Hands-off delivery (each owner; P3 shows dispatch)

| Say (P3) | Do / show |
|---|---|
| "A visible version change, merged to main — no manual deploy after." | Open the merged PR that bumped dispatch `/health` version |
| "The merge auto-triggered the pipeline." | CodePipeline → execution history, Source triggered by the merge commit |
| "Build tested, built, SHA-tagged, pushed, emitted imagedefinitions.json." | CodeBuild logs: pytest + `docker push` + `imagedefinitions.json` |
| "ECS deployed a new revision automatically." | `aws ecs describe-services --cluster $CL --services devops-g1-dispatch-service-svc --region us-east-1 --query 'services[0].taskDefinition'` |
| "New version is live." | Exec in → `curl -s http://localhost:3003/health` shows the new version |

> To make it *live*, bump the version again (`1.1.0`→`1.1.1`) and merge during the demo; zero manual steps after merge.

---

## Demo 7 — Automatic rollback / Gate 3B (each owner; P3 shows dispatch)

**Setup (before demo): must have a known-good deployment already live.** Then deploy a revision whose health check fails.
| Say (P3) | Do / show |
|---|---|
| "I deploy a revision that fails its health check on purpose." | trigger a bad revision (e.g., health path/port wrong) |
| "New tasks start, fail health checks, circuit breaker fires." | ECS service **events** show `circuit breaker` + rollback |
| "ECS restores the last known-good revision automatically." | `deployments[]` returns to prior revision; `curl http://localhost:3003/health` healthy again |
Record: failed revision #, ECS+ALB failure evidence, circuit-breaker event, restored revision, recovery, user impact.

---

## Demo 8 — Best scar (team; recommend P3's Service Connect DNS scar)

Present in the 5-field arc: **Symptom → Wrong hypothesis → Evidence → Actual cause → Prevention.**
> "Callback dispatch→ride-api failed with DNS `NameResolutionError`, even though the SG rule was correct. First we suspected the firewall. Evidence: logs showed name resolution failing, not a refused connection; task-start time predated ride-api's namespace registration. Actual cause: **Service Connect resolves a task's client endpoints at launch time** — dispatch launched before ride-api joined `group1.internal`. Prevention: redeploy dependents after a late namespace join, or sequence registration first."

---

## Closing (30 sec)
"Evidence over green: every boundary proven both ways, every failure logged with root cause, delivery fully hands-off, rollback automatic. Cleanup runs after grading in the documented order — ALB first, default VPC never deleted."
