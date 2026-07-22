# Group 1 — Demo Day Script (word-for-word)

Speak the **plain lines**. `[ACTION]` = do this / share this screen. `[VERIFY]` = what the reviewer
should see. **P1** = ride-api owner, **P2** = matching owner, **P3** = dispatch owner (you).
Real values are baked in. Keep it calm; lead with evidence.

---

## PART 0 — Open (P1)

**P1:** "Hi everyone, this is Group 1. Our region is us-east-1. We rehosted the three-service
ride-hailing app on ECS Fargate: a public ride-api behind an Application Load Balancer, and two
internal services — matching-service and dispatch-service — discovered over Service Connect.
I'll start with a 90-second architecture overview, then each of us demos our own service, and then
we prove the system end to end."

`[ACTION: P1 shares the architecture diagram / the "AWS services and why" table from the runbook.]`

**P1:** "The request flow is: internet hits the ALB on port 80; the ALB forwards to ride-api on
3001; ride-api calls matching-service on 3002; matching calls dispatch on 3003; and dispatch calls
back to ride-api to report the driver was assigned. Every hop is permitted by exactly one security
group rule, and services find each other by name through Service Connect, never by IP. Delivery is
hands-off — a merge to main flows through CodePipeline to ECS with no manual step. Let's start with
individual ownership. I'll go first with ride-api."

---

## PART 1 — Demo 1: Individual ownership

### P1 — ride-api (5 min)

**P1:** "ride-api is the only public service, running two tasks for availability. Here's my image,
tagged with the Git SHA — never latest."
`[ACTION: run] aws ecr describe-images --repository-name devops-g1-ride-api --region us-east-1 --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].imageTags`
`[VERIFY: one SHA tag.]`

**P1:** "This is my task definition — Fargate, awsvpc networking, port 3001 named, and it binds to
0.0.0.0 so the load balancer can reach it."
`[ACTION: Console → ECS → Task definitions → devops-g1-ride-api → latest revision]`

**P1:** "My service keeps two tasks alive and is registered into the ALB target group. My security
group allows inbound 3001 only from the ALB, plus the dispatch callback."
`[ACTION: run] aws ec2 describe-security-groups --group-ids sg-040f8062783e4fc92 --region us-east-1 --query 'SecurityGroups[0].IpPermissions'`
`[VERIFY: 3001 from alb-sg and dispatch-sg only.]`

**P1:** "And here's a live health check through the public ALB."
`[ACTION: run] curl -s http://devops-g1-alb-308819154.us-east-1.elb.amazonaws.com/health`
`[VERIFY: 200 with ride-api health JSON.]`

**P1:** "My delivery pipeline and version match the running SHA. That's ride-api. Over to P2."

### P2 — matching-service (5 min)

**P2:** "matching-service is internal only — no public target group. One task. Here's my SHA-tagged
image."
`[ACTION: run] aws ecr describe-images --repository-name devops-g1-matching-service --region us-east-1 --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].imageTags`

**P2:** "My security group allows inbound 3002 only from ride-api — nothing else."
`[ACTION: run] aws ec2 describe-security-groups --group-ids sg-04ce39108e5f243bf --region us-east-1 --query 'SecurityGroups[0].IpPermissions'`
`[VERIFY: 3002 from ride-api-sg only.]`

**P2:** "I'll prove it's healthy and can reach dispatch from inside its own task."
`[ACTION: run] TASK=$(aws ecs list-tasks --cluster devops-g1-cluster --service-name devops-g1-matching-service-svc --region us-east-1 --query 'taskArns[0]' --output text)`
`[ACTION: run] aws ecs execute-command --cluster devops-g1-cluster --task $TASK --container matching-service --interactive --command "/bin/sh" --region us-east-1`
`[ACTION: inside] curl -s http://dispatch-service:3003/health ; exit`
`[VERIFY: dispatch health JSON — proves B→C works.]`

**P2:** "I also own the ALB and target group, which P1's service registers into. Over to P3."

### P3 — dispatch-service (5 min) — YOU

P3 — dispatch-service (5 min) — YOU
P3: "dispatch-service is the last hop — it does the final assign and calls back to ride-api. Internal only, one task. First, my image, tagged with the Git commit SHA."
[ACTION: Console → ECR → Repositories → devops-g1-dispatch-service]
[VERIFY: top image row (most recent "Pushed at") shows one SHA tag in the Image tags column.]
P3: "Here's my task definition — Fargate, awsvpc, port 3003 named, BIND_HOST set to 0.0.0.0, with an execution role for pulling the image and a task role for ECS Exec."
[ACTION: Console → ECS → Task definitions → devops-g1-dispatch-service → latest revision]
P3: "My service runs one task with the deployment circuit breaker, automatic rollback, and ECS Exec all enabled."
[ACTION: Console → ECS → Clusters → devops-g1-cluster → Services → devops-g1-dispatch-service-svc]
P3: "Security is least-privilege: dispatch accepts inbound on 3003 from one source only — matching-service. No internet, not even ride-api."
[ACTION: Console → VPC → Security groups → sg-0ac76246a829107fc → Inbound rules tab]
[VERIFY: exactly one rule — port 3003, source sg-04ce39108e5f243bf (matching-service).]
P3: "Here are my structured logs — each line carries a request_id and trace_id so one request is traceable across all three services."
[ACTION: Console → CloudWatch → Log groups → /ecs/devops-g1-dispatch-service → newest log stream]
[VERIFY: log lines carry request_id and trace_id.]
P3: "And here's the running version, live, from inside the container."
[ACTION: Console → ECS → Clusters → devops-g1-cluster → Services → devops-g1-dispatch-service-svc → Tasks tab → running task]
[VERIFY: task is Running/Healthy on the latest task-definition revision.]
:warning: Note: ECS Exec (execute-command) into the container is CLI-only — there's no console equivalent for an interactive shell. To keep this beat's live curl .../health with "version":"1.1.0", you'll need to keep that one command in the CLI. The console path above is the closest visual proof (task running on the current revision) but it won't show the version string.
P3: "Finally, my delivery is a three-stage pipeline — Source, Build, Deploy — and I own the CodeConnections connection all three pipelines reuse. That's dispatch-service."
[ACTION: Console → CodePipeline → Pipelines → devops-g1-dispatch-service-pipeline]

---

## PART 2 — Demo 2: End-to-end request (P1 drives)

**P1:** "Now we trace one real request across all three services with a single correlation ID."
`[ACTION: run] curl -s -X POST http://devops-g1-alb-308819154.us-east-1.elb.amazonaws.com/request-ride -H 'X-Request-ID: DEMO-TRACE-001' -H 'Content-Type: application/json' -d '{"rider":"demo"}'`
`[VERIFY: JSON showing driver assigned.]`

**P1:** "The same ID, DEMO-TRACE-001, is in ride-api's logs."
`[ACTION: run] aws logs filter-log-events --log-group-name /ecs/devops-g1-ride-api --region us-east-1 --filter-pattern '"DEMO-TRACE-001"' --query 'events[].message'`

**P2:** "And in matching-service."
`[ACTION: run] aws logs filter-log-events --log-group-name /ecs/devops-g1-matching-service --region us-east-1 --filter-pattern '"DEMO-TRACE-001"' --query 'events[].message'`

**P3:** "And in dispatch-service, including the callback to ride-api."
`[ACTION: run] aws logs filter-log-events --log-group-name /ecs/devops-g1-dispatch-service --region us-east-1 --filter-pattern '"DEMO-TRACE-001"' --query 'events[].message'`

**P1:** "Same correlation ID in all three — that's the full chain, discovered by Service Connect
name, permitted by security groups at each hop."

---

## PART 3 — Demo 3: Security boundaries (P2 allow, P3 deny)

**P2:** "First the allowed paths. Internet to the ALB:"
`[ACTION: run] curl -i http://devops-g1-alb-308819154.us-east-1.elb.amazonaws.com/health`
`[VERIFY: HTTP 200.]`

**P2:** "ride-api to matching, from inside ride-api's task:"
`[ACTION: Exec into ride-api task] curl -i --max-time 5 http://matching-service:3002/health`
`[VERIFY: 200.]`

**P3:** "Now the denied path — the important one. From inside ride-api's task, I try to reach
dispatch directly. Our design forbids ride-api → dispatch; the flow must go through matching."
`[ACTION: Exec into ride-api task] curl -i --max-time 5 http://dispatch-service:3003/health`
`[VERIFY: times out after 5s — no response.]`

**P3:** "That timeout is the security group doing its job. Here's the config proof — dispatch only
accepts 3003 from matching-service, so ride-api's packets are dropped."
`[ACTION: run] aws ec2 describe-security-groups --group-ids sg-0ac76246a829107fc --region us-east-1 --query 'SecurityGroups[0].IpPermissions[].{port:FromPort,src:UserIdGroupPairs[0].GroupId}'`
`[VERIFY: only matching-sg → 3003.]`

**P2:** "So: allowed paths succeed, the forbidden path times out, and the security-group rules
explain exactly why. Two evidence types, runtime and config."

---

## PART 4 — Demo 4: Failure diagnosis (team, reviewer injects)

**Reviewer:** *(injects a fault)*

**P (whoever owns it):** "Symptom first — here's what a user sees."
`[ACTION: reproduce, e.g.] curl -i http://devops-g1-alb-308819154.us-east-1.elb.amazonaws.com/`
**P:** "My first hypothesis is ___. Let me check the evidence before touching anything."
`[ACTION: run] aws ecs describe-services --cluster devops-g1-cluster --services <svc> --region us-east-1 --query 'services[0].events[:5]'`
`[ACTION: run] aws ecs describe-tasks --cluster devops-g1-cluster --tasks <task> --region us-east-1 --query 'tasks[0].stoppedReason'`
`[ACTION: run] aws elbv2 describe-target-health --target-group-arn arn:aws:elasticloadbalancing:us-east-1:827478161993:targetgroup/devops-g1-ride-api-tg/93f114ed1201b587 --region us-east-1`
**P:** "The evidence points to ___ as the root cause. The repair is ___. We'll log this in the scar
log." *(No console takeover; evidence decides.)*

---

## PART 5 — Demo 5: Availability / kill a task (P1)

**P1:** "I'll run continuous traffic while I kill a ride-api task, to show the second task absorbs
it."
`[ACTION: Terminal A] while true; do date; curl -s -o /dev/null -w "status=%{http_code} time=%{time_total}\n" http://devops-g1-alb-308819154.us-east-1.elb.amazonaws.com/health; sleep 1; done`
`[ACTION: Terminal B] T=$(aws ecs list-tasks --cluster devops-g1-cluster --service-name devops-g1-ride-api-svc --region us-east-1 --query 'taskArns[0]' --output text)`
`[ACTION: Terminal B] aws ecs stop-task --cluster devops-g1-cluster --task $T --region us-east-1`
`[VERIFY: statuses stay 200 (maybe one blip); ECS starts a replacement; target health goes unhealthy→healthy.]`

**P1:** "Because ride-api runs desired count two, there's always a healthy task. With count one —
like matching and dispatch — there'd be a brief outage until the replacement passed its health
check. That's why only the public service runs two."

---

## PART 6 — Demo 6: Hands-off delivery (P3 leads)

**P3:** "I'll make a visible version change and merge it — after the merge I won't touch AWS at
all."
`[ACTION: run] git checkout main && git pull`
`[ACTION: run] git checkout -b demo/bump-version`
`[ACTION: edit] bump VERSION in services/dispatch-service/app.py (1.1.0 → 1.1.1)`
`[ACTION: run] git commit -am "Bump dispatch-service /health version for demo"`
`[ACTION: run] git push -u origin demo/bump-version`
`[ACTION: run] gh pr create --fill`
**P3:** "I'll approve and merge on GitHub… and now I'm hands-off. Watch the pipeline trigger by
itself."
`[ACTION: Console → CodePipeline → devops-g1-dispatch-service-pipeline — watch Source → Build → Deploy]`
**P3:** "Build ran the tests, built the image, tagged it with the new SHA, pushed to ECR, and wrote
imagedefinitions.json. Deploy registered a new task-def revision automatically."
`[ACTION: run] aws codepipeline get-pipeline-state --name devops-g1-dispatch-service-pipeline --region us-east-1 --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table`
`[VERIFY: all Succeeded.]`
**P3:** "And the new version is live — 1.1.1 — with no manual deploy step."
`[ACTION: Exec into dispatch task] curl -s http://localhost:3003/health`
`[VERIFY: version 1.1.1.]`

---

## PART 7 — Demo 7: Automatic rollback (P3)

**P3:** "We have a known-good deployment live. Now I deploy a revision that fails its health check
on purpose, to show the circuit breaker roll it back automatically."
`[ACTION: trigger a bad revision — health check pointed at the wrong port]`
**P3:** "New tasks start, fail their health checks, and instead of leaving us broken, ECS's
deployment circuit breaker activates and restores the last known-good revision."
`[ACTION: run] aws ecs describe-services --cluster devops-g1-cluster --services devops-g1-dispatch-service-svc --region us-east-1 --query 'services[0].events[:8]'`
`[VERIFY: "circuit breaker" + rollback events; service back on the prior revision.]`
**P3:** "Recovery was automatic, and users never saw the broken revision serve traffic."

---

## PART 8 — Demo 8: Best scar (P3 tells it)

**P3:** "Our best scar is a Service Connect one. Symptom: dispatch's callback to ride-api failed
with a DNS name-resolution error — even though the security-group rule allowing it was correct.
Our first hypothesis was the firewall. But the evidence disagreed: the logs showed name resolution
failing, not a refused connection, and dispatch's task had started more than an hour before ride-api
registered in the namespace. The actual cause: Service Connect wires a task's client endpoints at
launch time, so dispatch never learned ride-api existed. The prevention: redeploy dependents after
a service joins the namespace late — or register everything before starting dependents. It's the
clearest lesson we got: the cloud is a dependency graph, and timing is one of its edges."

---

## PART 9 — Close (P1)

**P1:** "To summarize: three independently owned services, every boundary proven in both
directions, one request traced end to end by correlation ID, delivery fully hands-off, rollback
automatic, and every failure documented with root-cause evidence. We'll tear down after grading in
the documented order — pipelines and load balancer first, default VPC never deleted. Thank you —
happy to take questions."

---

## PART 10 — Likely reviewer questions + prepared answers

**Q: "P3, why does ride-api run two tasks but yours runs one?"**
> "ride-api is the only public service, so it needs a standby to absorb traffic during task
> replacement — desired count two means near-zero failed requests when a task dies. The internal
> services aren't user-facing, so count one is acceptable; a brief gap during replacement doesn't
> hit end users directly."

**Q: "Why is ride-api → dispatch denied when dispatch calls ride-api back?"**
> "The application flow is strictly A→B→C, then C calls back to A. ride-api never calls dispatch
> directly, so we don't open that path — least privilege. The callback edge C→A is a separate,
> explicitly-allowed rule on ride-api's security group."

**Q: "How does dispatch find ride-api without an IP?"**
> "Service Connect. ride-api registers the name `ride-api` in the `group1.internal` namespace, and
> dispatch calls `http://ride-api:3001`. The proxy resolves the name to healthy task IPs — which is
> exactly why our DNS scar happened when the timing was wrong."

**Q: "What makes your image immutable, and why?"**
> "The ECR repo is set to IMMUTABLE and we tag with the Git commit SHA, never latest. A given SHA
> can never be overwritten, so what's deployed always maps to an exact commit. It also means
> re-running the same commit fails the push — which is correct: one commit, one image."

**Q: "Prove nothing is deployed outside your region."**
> "Our IAM permissions boundary restricts us to us-east-1 — we literally can't create resources
> elsewhere. Everything you've seen is in us-east-1."

**Q (cross-ownership, to P3 about a teammate): "What's P2's target group type and why?"**
> "Type `ip`, because Fargate tasks use awsvpc networking — each task gets its own ENI/IP, so the
> ALB targets IPs directly rather than instances."
