# matching-service — Build Book (Person 2, Group 1)

**Advisory reference.** matching-service and its platform pieces are **Person 2's** resources —
P2 runs these on their own console/CLI. Documented so the team shares one method.

matching-service is **internal only** (never public, no ALB target group), desired count **1**.
Person 2 also owns the **ALB** and the **target group** (platform).

**Locked values**
| Thing | Value |
|---|---|
| Region / Account | `us-east-1` / `827478161993` |
| ECR repo | `devops-g1-matching-service` |
| Task def / container | `devops-g1-matching-service` / `matching-service` |
| ECS service | `devops-g1-matching-service-svc` |
| Port | `3002` · desired count **1** |
| matching SG | `sg-04ce39108e5f243bf` |
| Log group | `/ecs/devops-g1-matching-service` |
| Downstream env | `DISPATCH_SERVICE_URL=http://dispatch-service:3003` |
| ALB (platform) | `devops-g1-alb` (`devops-g1-alb-308819154.us-east-1.elb.amazonaws.com`) |
| ALB SG (platform) | `sg-0edf8cf5f87caee80` |
| Target group (platform) | `devops-g1-ride-api-tg` |

**Tags (all resources):** `Project=devops-mentorship Group=group-1 Owner=matching-service-owner Environment=lab`
*(platform resources use `Owner=platform-owner`)*

---

## Platform first (P2 owns these — the public front door)

### P-1. ALB security group (terminal)
```bash
# create alb-sg in default VPC, then allow the internet in on :80
aws ec2 authorize-security-group-ingress --group-id sg-0edf8cf5f87caee80 --region us-east-1 \
  --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description="internet to ALB:80"}]'
```
*Only the ALB is internet-facing; this is the sole public inbound rule in the whole system.*

### P-2. Target group (terminal)
```bash
aws elbv2 create-target-group --name devops-g1-ride-api-tg --protocol HTTP --port 3001 \
  --vpc-id <default-vpc-id> --target-type ip --health-check-path /health --region us-east-1 \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=platform-owner Key=Environment,Value=lab
```
*Target type **ip** (required for Fargate/awsvpc). Health check `/health`. Only **ride-api** registers here — matching/dispatch have NO public target group.*

### P-3. Application Load Balancer + listener (terminal)
```bash
aws elbv2 create-load-balancer --name devops-g1-alb --type application --scheme internet-facing \
  --subnets <subnet-az-a> <subnet-az-b> --security-groups sg-0edf8cf5f87caee80 --region us-east-1 \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=platform-owner Key=Environment,Value=lab
# then create the HTTP:80 listener that forwards to the target group
aws elbv2 create-listener --load-balancer-arn <alb-arn> --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=<target-group-arn> --region us-east-1
```
*Internet-facing, 2 AZs (us-east-1a/1b), HTTP:80 listener → ride-api target group.*
> **Console alt:** AWS Console → **EC2 → Load Balancers → Create load balancer → Application Load Balancer** → internet-facing, 2 AZs, security group `devops-g1-alb-sg`, listener HTTP:80 → forward to `devops-g1-ride-api-tg`.
> **Prereq:** ride-api's ECS service links itself to this target group (see ride-api build book step 6) — P2 creates the TG/ALB, P1 registers ride-api into it.

---

## Phase 2 — Host matching-service

### 1. ECR + image (terminal)
```bash
export SHA=$(git rev-parse --short HEAD)
export ECR_URI=827478161993.dkr.ecr.us-east-1.amazonaws.com/devops-g1-matching-service
aws ecr create-repository --repository-name devops-g1-matching-service --region us-east-1 --image-tag-mutability IMMUTABLE \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=matching-service-owner Key=Environment,Value=lab
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 827478161993.dkr.ecr.us-east-1.amazonaws.com
docker build --platform linux/amd64 -f services/matching-service/Dockerfile -t $ECR_URI:$SHA .
docker push $ECR_URI:$SHA
```
*(matching-service Dockerfile COPY fix already merged in #23.)*

### 2. IAM roles / 3. Log group
Reuse shared roles (dispatch build book step 3). Log group:
```bash
aws logs create-log-group --log-group-name /ecs/devops-g1-matching-service --region us-east-1 \
  --tags Project=devops-mentorship,Group=group-1,Owner=matching-service-owner,Environment=lab
```

### 4. Security group inbound rule (terminal)
```bash
# allow ONLY ride-api -> matching:3002
aws ec2 authorize-security-group-ingress --group-id sg-04ce39108e5f243bf --region us-east-1 \
  --ip-permissions 'IpProtocol=tcp,FromPort=3002,ToPort=3002,UserIdGroupPairs=[{GroupId=sg-040f8062783e4fc92,Description="ride-api to matching:3002"}]'
```
*The only inbound matching accepts (source = ride-api SG `sg-040f8062783e4fc92`). No internet, no dispatch.*

### 5. Task definition (terminal)
Same shape as dispatch: Fargate/awsvpc, image `:$SHA`, named port `3002`, `BIND_HOST=0.0.0.0`,
`DISPATCH_SERVICE_URL=http://dispatch-service:3003`, log group `/ecs/devops-g1-matching-service`, health `/health`.
```bash
aws ecs register-task-definition --cli-input-json file://aws/devops-g1-matching-service-taskdef.json --region us-east-1 --tags key=Project,value=devops-mentorship key=Group,value=group-1 key=Owner,value=matching-service-owner key=Environment,value=lab
```

### 6. ECS service — Service Connect, NO ALB (terminal)
```bash
aws ecs create-service --cluster devops-g1-cluster --service-name devops-g1-matching-service-svc \
  --task-definition devops-g1-matching-service --desired-count 1 --launch-type FARGATE --region us-east-1 \
  --enable-execute-command \
  --network-configuration "awsvpcConfiguration={subnets=[<2 subnets>],securityGroups=[sg-04ce39108e5f243bf],assignPublicIp=ENABLED}" \
  --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true}" \
  --service-connect-configuration '{"enabled":true,"namespace":"group1.internal","services":[{"portName":"matching-service","clientAliases":[{"dnsName":"matching-service","port":3002}]}]}' \
  --tags key=Project,value=devops-mentorship key=Group,value=group-1 key=Owner,value=matching-service-owner key=Environment,value=lab
```
*Desired count **1**, **no `--load-balancers`** (internal only). Service Connect advertises `matching-service:3002` and gives it client access to dispatch-service.*

### 7. Verify (terminal)
```bash
aws ecs describe-tasks --cluster devops-g1-cluster --tasks $(aws ecs list-tasks --cluster devops-g1-cluster --service-name devops-g1-matching-service-svc --region us-east-1 --query 'taskArns[0]' --output text) --region us-east-1 --query 'tasks[0].{status:lastStatus,health:healthStatus}'
# from inside the matching task (ECS Exec): curl -fs http://dispatch-service:3003/health   -> proves B->C works
```

---

## Phase 5 — matching-service pipeline
Identical shape to the dispatch build book steps 11–17, substituting `matching-service`:
buildspec `buildspecs/matching-service.yml` (on `main`) · CodeBuild `devops-g1-matching-service-build` ·
pipeline `devops-g1-matching-service-pipeline` (Deploy → `devops-g1-matching-service-svc`). Reuse the
**shared CodeConnections** connection — do not create a new one.

**Gate 3A note:** matching-service is internal, so prove "new version live" via ECS Exec
(`curl http://localhost:3002/health`), not through the ALB.
