# ride-api — Build Book (Person 1, Group 1)

**Advisory reference.** ride-api and its platform pieces are **Person 1's** resources — P1 runs
these on their own console/CLI. This documents the sequence so the team shares one method.

ride-api is the **only public** service (behind the ALB), desired count **2**. Person 1 also owns
the **ECS cluster** and the **Service Connect namespace** (platform).

**Locked values**
| Thing | Value |
|---|---|
| Region / Account | `us-east-1` / `827478161993` |
| ECR repo | `devops-g1-ride-api` |
| Task def / container | `devops-g1-ride-api` / `ride-api` |
| ECS service | `devops-g1-ride-api-svc` |
| Port | `3001` · desired count **2** |
| ride-api SG | `sg-040f8062783e4fc92` |
| Log group | `/ecs/devops-g1-ride-api` |
| Downstream env | `MATCHING_SERVICE_URL=http://matching-service:3002` |
| ALB target group (P2) | `devops-g1-ride-api-tg` |
| ALB SG (P2) | `sg-0edf8cf5f87caee80` |

**Tags (all resources):** `Project=devops-mentorship Group=group-1 Owner=ride-api-owner Environment=lab`
*(platform resources use `Owner=platform-owner`)*

---

## Platform first (P1 owns these — needed by everyone)

### P-1. ECS cluster (terminal)
```bash
aws ecs create-cluster --cluster-name devops-g1-cluster \
  --settings name=containerInsights,value=enabled --region us-east-1 \
  --tags key=Project,value=devops-mentorship key=Group,value=group-1 key=Owner,value=platform-owner key=Environment,value=lab
```
*Logical grouping for tasks; Container Insights on for metrics. Runs no compute itself.*
> **Console alt:** AWS Console → **ECS → Clusters → Create cluster** → name `devops-g1-cluster`, Fargate, enable Container Insights.

### P-2. Service Connect namespace (terminal)
```bash
aws servicediscovery create-http-namespace --name group1.internal --region us-east-1
```
*Cloud Map namespace that lets services resolve each other by name (`http://matching-service:3002`). Every service registers into this.*
> **Console alt:** AWS Console → **AWS Cloud Map → Namespaces → Create namespace** → `group1.internal` (API/HTTP). Can also be created inline when creating the cluster in the ECS console.
> **Note:** create this **before** any service's ECS service, and remember services that join later require already-running dependents to redeploy (Service Connect resolves endpoints at task launch).

---

## Phase 2 — Host ride-api

### 1. ECR + image (terminal)
```bash
export SHA=$(git rev-parse --short HEAD)
export ECR_URI=827478161993.dkr.ecr.us-east-1.amazonaws.com/devops-g1-ride-api
aws ecr create-repository --repository-name devops-g1-ride-api --region us-east-1 --image-tag-mutability IMMUTABLE \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=ride-api-owner Key=Environment,Value=lab
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 827478161993.dkr.ecr.us-east-1.amazonaws.com
docker build --platform linux/amd64 -f services/ride-api/Dockerfile -t $ECR_URI:$SHA .
docker push $ECR_URI:$SHA
```
*Create registry, auth, build (amd64, repo-root context), push SHA-tagged image. (ride-api Dockerfile COPY fix already merged in #26.)*

### 2. IAM roles (terminal)
Reuse the shared roles if they exist (`devops-g1-ecs-execution-role`, `devops-g1-ecs-task-role`) — see the dispatch build book step 3. `EntityAlreadyExists` = already made, skip.

### 3. Log group (terminal)
```bash
aws logs create-log-group --log-group-name /ecs/devops-g1-ride-api --region us-east-1 \
  --tags Project=devops-mentorship,Group=group-1,Owner=ride-api-owner,Environment=lab
```

### 4. Security group + inbound rules (terminal)
```bash
# create ride-api SG (in default VPC) — same pattern as dispatch build book step 5
# then allow ALB -> ride-api:3001  AND  dispatch -> ride-api:3001 (the callback)
aws ec2 authorize-security-group-ingress --group-id sg-040f8062783e4fc92 --region us-east-1 \
  --ip-permissions 'IpProtocol=tcp,FromPort=3001,ToPort=3001,UserIdGroupPairs=[{GroupId=sg-0edf8cf5f87caee80,Description="ALB to ride-api:3001"}]'
aws ec2 authorize-security-group-ingress --group-id sg-040f8062783e4fc92 --region us-east-1 \
  --ip-permissions 'IpProtocol=tcp,FromPort=3001,ToPort=3001,UserIdGroupPairs=[{GroupId=sg-0ac76246a829107fc,Description="dispatch callback to ride-api:3001"}]'
```
*Two inbound sources on 3001: the ALB (public traffic) and dispatch-service (the `/driver-assigned` callback — this edge is required by the app flow A→B→C→A even though the original Gate 1 matrix only drew A→B→C).*

### 5. Task definition (terminal)
Same shape as dispatch: Fargate/awsvpc, image `:$SHA`, named port `3001`, `BIND_HOST=0.0.0.0`,
`MATCHING_SERVICE_URL=http://matching-service:3002`, log group `/ecs/devops-g1-ride-api`, health `/health`, exec+task roles.
```bash
aws ecs register-task-definition --cli-input-json file://aws/devops-g1-ride-api-taskdef.json --region us-east-1 --tags key=Project,value=devops-mentorship key=Group,value=group-1 key=Owner,value=ride-api-owner key=Environment,value=lab
```

### 6. ECS service — with Service Connect AND ALB (terminal)
```bash
aws ecs create-service --cluster devops-g1-cluster --service-name devops-g1-ride-api-svc \
  --task-definition devops-g1-ride-api --desired-count 2 --launch-type FARGATE --region us-east-1 \
  --enable-execute-command \
  --network-configuration "awsvpcConfiguration={subnets=[<2 subnets>],securityGroups=[sg-040f8062783e4fc92],assignPublicIp=ENABLED}" \
  --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true}" \
  --load-balancers "targetGroupArn=arn:aws:elasticloadbalancing:us-east-1:827478161993:targetgroup/devops-g1-ride-api-tg/93f114ed1201b587,containerName=ride-api,containerPort=3001" \
  --service-connect-configuration '{"enabled":true,"namespace":"group1.internal","services":[{"portName":"ride-api","clientAliases":[{"dnsName":"ride-api","port":3001}]}]}' \
  --tags key=Project,value=devops-mentorship key=Group,value=group-1 key=Owner,value=ride-api-owner key=Environment,value=lab
```
*Desired count **2** (only public service — absorbs traffic during task replacement). `--load-balancers` auto-registers task IPs into P2's target group. Service Connect advertises `ride-api:3001` and gives it client access to matching-service.*
> **Prereq:** P2's ALB + target group must exist first (see matching-service build book).

### 7. Verify (terminal)
```bash
aws ecs describe-tasks --cluster devops-g1-cluster --tasks $(aws ecs list-tasks --cluster devops-g1-cluster --service-name devops-g1-ride-api-svc --region us-east-1 --query 'taskArns[0]' --output text) --region us-east-1 --query 'tasks[0].{status:lastStatus,health:healthStatus}'
aws elbv2 describe-target-health --target-group-arn arn:aws:elasticloadbalancing:us-east-1:827478161993:targetgroup/devops-g1-ride-api-tg/93f114ed1201b587 --region us-east-1 --query 'TargetHealthDescriptions[].TargetHealth.State'   # want "healthy"
curl -s http://devops-g1-alb-308819154.us-east-1.elb.amazonaws.com/health                                                                # public 200
```

---

## Phase 5 — ride-api pipeline
Identical shape to the dispatch build book steps 11–17, substituting `ride-api`:
buildspec `buildspecs/ride-api.yml` (on `main`) · CodeBuild `devops-g1-ride-api-build` · pipeline
`devops-g1-ride-api-pipeline` (Deploy → service `devops-g1-ride-api-svc`). Reuse the **shared
CodeConnections** connection (`devops-g1-github-connection`) — do not create a new one.

**Gate 3A note:** because ride-api is behind the ALB, its "new SHA visible through ALB" proof is
`curl http://<alb>/health` after merge (dispatch/matching prove it via ECS Exec instead).
