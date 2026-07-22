# dispatch-service — Build Book (Person 3, Group 1)

Every command, in order, to take dispatch-service from nothing → running on Fargate →
wired → hands-off delivery, plus the CodeConnections platform piece. Console steps include
full navigation paths.

**Locked values**
| Thing | Value |
|---|---|
| Region | `us-east-1` |
| Account | `827478161993` |
| Cluster | `devops-g1-cluster` (owned by P1) |
| Namespace | `group1.internal` (owned by P1) |
| ECR repo | `devops-g1-dispatch-service` |
| Task def / container name | `devops-g1-dispatch-service` / `dispatch-service` |
| ECS service | `devops-g1-dispatch-service-svc` |
| dispatch SG | `sg-0ac76246a829107fc` |
| matching SG (source) | `sg-04ce39108e5f243bf` |
| Log group | `/ecs/devops-g1-dispatch-service` |
| CodeConnections ARN | `arn:aws:codeconnections:us-east-1:827478161993:connection/5fe9c0fb-8146-4afc-9d74-018bd3a86313` |

**Required tags on every resource:** `Project=devops-mentorship Group=group-1 Owner=dispatch-service-owner Environment=lab`

> ⚠️ Your IAM user has a **permissions boundary scoped to us-east-1** and to the `devops-g1-` name prefix. Keep everything in us-east-1; name every role `devops-g1-...` (that's why the pipeline role is created by CLI, not the Console auto-role).

---

## Stage 0 — Session setup (terminal)

```bash
cd /home/code0061/devops/production-service-env
export AWS_REGION=us-east-1
export ACCOUNT_ID=827478161993
export SHA=$(git rev-parse --short HEAD)                 # short Git SHA = image tag
export ECR_URI=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/devops-g1-dispatch-service
aws sts get-caller-identity                              # confirm correct account
```
*Sets reusable variables and verifies the CLI is pointed at account 827478161993. Run all later commands in this same terminal so the variables persist.*

---

## Phase 2 — Host the service

### 1. ECR repository (terminal)
```bash
aws ecr create-repository --repository-name devops-g1-dispatch-service --region $AWS_REGION \
  --image-tag-mutability IMMUTABLE \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=dispatch-service-owner Key=Environment,Value=lab
```
*Creates the private image registry. IMMUTABLE = a SHA tag can never be overwritten (enforces one-commit-one-image; re-running the same commit will fail the push by design).*

### 2. Build & push the image (terminal)
```bash
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com   # auth Docker to ECR
docker build --platform linux/amd64 -f services/dispatch-service/Dockerfile -t $ECR_URI:$SHA .                                                # build (amd64 for Fargate; context = repo root)
docker push $ECR_URI:$SHA                                                                                                                      # push SHA-tagged image
aws ecr describe-images --repository-name devops-g1-dispatch-service --region $AWS_REGION --query 'imageDetails[].imageTags'                    # verify tag landed
```

### 3. IAM roles (terminal) — files in `aws/`
```bash
# Execution role (lets ECS pull the image + write logs)
aws iam create-role --role-name devops-g1-ecs-execution-role \
  --assume-role-policy-document file://aws/ecs-tasks-trust-policy.json \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=dispatch-service-owner Key=Environment,Value=lab
aws iam attach-role-policy --role-name devops-g1-ecs-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Task role (lets the running container use ECS Exec via SSM)
aws iam create-role --role-name devops-g1-ecs-task-role \
  --assume-role-policy-document file://aws/ecs-tasks-trust-policy.json \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=dispatch-service-owner Key=Environment,Value=lab
aws iam put-role-policy --role-name devops-g1-ecs-task-role \
  --policy-name ecs-exec-ssm --policy-document file://aws/ecs-exec-task-role-policy.json
```
*Execution role = pull image + logging (AWS-managed policy). Task role = runtime SSM permissions for ECS Exec. `EntityAlreadyExists` means it's already made — safe to skip.*

### 4. CloudWatch log group (terminal)
```bash
aws logs create-log-group --log-group-name /ecs/devops-g1-dispatch-service --region $AWS_REGION \
  --tags Project=devops-mentorship,Group=group-1,Owner=dispatch-service-owner,Environment=lab
```
*The task definition writes here; create it first so the awslogs driver has a target.*

### 5. Security group (terminal)
```bash
export DEFAULT_VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
export SUBNET_LIST=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$DEFAULT_VPC Name=default-for-az,Values=true --query 'Subnets[].SubnetId' --output text --region $AWS_REGION | tr '\t' '\n' | head -2 | paste -sd, -)
export DISPATCH_SG=$(aws ec2 create-security-group --group-name devops-g1-dispatch-service-sg \
  --description "dispatch-service SG - inbound 3003 from matching-service only" --vpc-id $DEFAULT_VPC --region $AWS_REGION \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Project,Value=devops-mentorship},{Key=Group,Value=group-1},{Key=Owner,Value=dispatch-service-owner},{Key=Environment,Value=lab}]' \
  --query 'GroupId' --output text)
echo "VPC=$DEFAULT_VPC SUBNETS=$SUBNET_LIST SG=$DISPATCH_SG"
```
*Finds the default VPC + two subnets in different AZs, and creates the service's dedicated SG (no inbound rule yet — added in Phase 3).*

### 6. Register the task definition (terminal)
```bash
aws ecs register-task-definition --cli-input-json file://aws/devops-g1-dispatch-service-taskdef.json --region $AWS_REGION \
  --tags key=Project,value=devops-mentorship key=Group,value=group-1 key=Owner,value=dispatch-service-owner key=Environment,value=lab
```
*Registers the Fargate/awsvpc recipe: SHA image, named port 3003, `BIND_HOST=0.0.0.0`, log group, both role ARNs, health check on `/health`. Expect `"status":"ACTIVE"`, `"revision":1`.*

### 7. Create the ECS service + Service Connect (terminal)
```bash
aws ecs create-service --cluster $CL --service-name devops-g1-dispatch-service-svc \
  --task-definition devops-g1-dispatch-service --desired-count 1 --launch-type FARGATE --region $AWS_REGION \
  --enable-execute-command \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_LIST],securityGroups=[$DISPATCH_SG],assignPublicIp=ENABLED}" \
  --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true}" \
  --service-connect-configuration '{"enabled":true,"namespace":"group1.internal","services":[{"portName":"dispatch-service","clientAliases":[{"dnsName":"dispatch-service","port":3003}]}]}' \
  --tags key=Project,value=devops-mentorship key=Group,value=group-1 key=Owner,value=dispatch-service-owner key=Environment,value=lab
```
*Runs 1 task, ECS Exec on, circuit breaker + rollback on, public IP on (lab), and registers `dispatch-service:3003` in Service Connect. (`export CL=devops-g1-cluster` first.)*

### 8. Verify the checkpoint (terminal)
```bash
export CL=devops-g1-cluster
export TASK=$(aws ecs list-tasks --cluster $CL --service-name devops-g1-dispatch-service-svc --region $AWS_REGION --query 'taskArns[0]' --output text)
aws ecs describe-tasks --cluster $CL --tasks $TASK --region $AWS_REGION --query 'tasks[0].{lastStatus:lastStatus,health:healthStatus}'   # want RUNNING / HEALTHY
aws logs tail /ecs/devops-g1-dispatch-service --since 5m --region $AWS_REGION                                                            # app log visible
```

**One-time: install Session Manager plugin (needed for ECS Exec):**
```bash
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/smp.deb
sudo dpkg -i /tmp/smp.deb
```
**Then test ECS Exec:**
```bash
aws ecs execute-command --cluster $CL --task $TASK --container dispatch-service --interactive --command "/bin/sh" --region $AWS_REGION
# inside: curl -fs http://localhost:3003/health ; exit
```
*Checkpoint complete when: RUNNING, HEALTHY, log visible, SHA visible, Exec works.*

---

## Phase 3 — Wire the security boundary

### 9. Inbound rule: matching-service → dispatch:3003 (terminal)
```bash
aws ec2 authorize-security-group-ingress --group-id sg-0ac76246a829107fc \
  --ip-permissions 'IpProtocol=tcp,FromPort=3003,ToPort=3003,UserIdGroupPairs=[{GroupId=sg-04ce39108e5f243bf,Description="matching-service to dispatch-service:3003"}]' \
  --region $AWS_REGION
```
*The only inbound dispatch accepts. `sg-04ce39108e5f243bf` is Person 2's matching-service SG (look it up read-only if needed — reading another owner's SG ID is allowed; you only modify your own SG).*
Look up all group SGs: `aws ec2 describe-security-groups --region us-east-1 --filters "Name=group-name,Values=devops-g1-*" --query 'SecurityGroups[].{Name:GroupName,Id:GroupId}' --output table`

---

## Phase 5 — Ship it hands-off

### 10. CodeConnections — **AWS Console** (your platform piece)
> **Console path:** AWS Console → **Developer Tools → CodePipeline → Settings → Connections → Create connection**
> - Region selector (top-right) = **US East (N. Virginia)**.
> - Provider **GitHub** → name `devops-g1-github-connection` → **Connect to GitHub**.
> - Authorize the **AWS Connector for GitHub** app; install it on **only** the `production-service-env` repo.
> - Select the installation → **Connect**. Status must read **Available**.
> **Prereq:** you must be a GitHub admin on the repo (it's under `nebyathhailu`, so you are).
> **Why Console:** the GitHub OAuth handshake can't be completed by CLI.

**Verify + tag (terminal):**
```bash
aws codeconnections list-connections --region us-east-1 --query "Connections[?ConnectionName=='devops-g1-github-connection']" --output table
export CONN_ARN=arn:aws:codeconnections:us-east-1:827478161993:connection/5fe9c0fb-8146-4afc-9d74-018bd3a86313
aws codeconnections tag-resource --region us-east-1 --resource-arn $CONN_ARN \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=platform-owner Key=Environment,Value=lab
```
*All three pipelines reuse this one connection — share the ARN in the group chat.*

### 11. Buildspec — commit to `main` (terminal)
```bash
git checkout -b add/dispatch-buildspec
git add buildspecs/dispatch-service.yml
git commit -m "Add dispatch-service CodeBuild buildspec"
git push -u origin add/dispatch-buildspec
gh pr create --fill
```
*CodeBuild reads `buildspecs/dispatch-service.yml` from `main`, so it MUST be merged there before the pipeline runs. (Only the buildspec must be on main; the `aws/*.json` files are local CLI inputs.)*

### 12. CodeBuild service role (terminal)
```bash
aws iam create-role --role-name devops-g1-codebuild-role \
  --assume-role-policy-document file://aws/codebuild-trust-policy.json \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=dispatch-service-owner Key=Environment,Value=lab
aws iam put-role-policy --role-name devops-g1-codebuild-role \
  --policy-name codebuild-dispatch --policy-document file://aws/codebuild-dispatch-policy.json
```
*Least-privilege: ECR push, CloudWatch logs, artifact-bucket S3.*

### 13. CodeBuild project (terminal)
```bash
aws codebuild create-project --cli-input-json file://aws/devops-g1-dispatch-service-build.json --region $AWS_REGION
aws codebuild batch-get-projects --names devops-g1-dispatch-service-build --region $AWS_REGION \
  --query 'projects[0].{name:name,role:serviceRole,privileged:environment.privilegedMode,buildspec:source.buildspec}'
```
*Creates the build project: privileged mode (Docker), buildspec path, CODEPIPELINE source/artifacts, env vars ACCOUNT_ID/ECR_REPO/CONTAINER_NAME.*

### 14. CodePipeline service role (terminal) — needed before Console pipeline
```bash
aws iam create-role --role-name devops-g1-dispatch-pipeline-role \
  --assume-role-policy-document file://aws/codepipeline-trust-policy.json \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=dispatch-service-owner Key=Environment,Value=lab
aws iam put-role-policy --role-name devops-g1-dispatch-pipeline-role \
  --policy-name codepipeline-dispatch --policy-document file://aws/codepipeline-dispatch-policy.json
```
*UseConnection + artifact S3 + StartBuild + ECS deploy + `iam:PassRole` scoped to ONLY the two ECS roles. Create this first because the Console's auto-role is blocked by your permissions boundary (wrong name prefix).*

### 15. Create the pipeline — **AWS Console**
> **Console path:** AWS Console → **CodePipeline → Pipelines → Create pipeline** → **Build custom pipeline**
> **Settings step:** name `devops-g1-dispatch-service-pipeline`; **Service role → Existing service role → `devops-g1-dispatch-pipeline-role`**; Advanced → Artifact store = **Default**.
> **Source step:** provider **GitHub (via GitHub App)** → connection `devops-g1-github-connection` → repo `nebyathhailu/production-service-env` → branch `main`.
> **Build step:** provider **AWS CodeBuild** → region N. Virginia → project `devops-g1-dispatch-service-build`.
> **Deploy step:** provider **Amazon ECS** → cluster `devops-g1-cluster` → service `devops-g1-dispatch-service-svc` → image file `imagedefinitions.json`.
> **Prereq:** buildspec merged to `main` (step 11), and the pipeline role (step 14) exists.
> **Note:** if you go *Previous* in the wizard it can drop the Deploy stage — verify all three stages exist after creating (step 16).

### 16. If the Deploy stage is missing — add it in **Console**
> **Console path:** AWS Console → **CodePipeline → `devops-g1-dispatch-service-pipeline` → Edit** → below **Build**, **+ Add stage** → name `Deploy` → **+ Add action group**:
> - Action name `Deploy`, provider **Amazon ECS**, region N. Virginia
> - **Input artifacts: `BuildArtifact`** (this carries `imagedefinitions.json`)
> - Cluster `devops-g1-cluster`, Service `devops-g1-dispatch-service-svc`, image file `imagedefinitions.json`
> **Save**, then **Release change**.

**Verify all three stages (terminal):**
```bash
aws codepipeline get-pipeline --name devops-g1-dispatch-service-pipeline --region us-east-1 --query 'pipeline.stages[].name' --output text   # want: Source Build Deploy
```

### 17. Gate 3A — hands-off deploy by merge (terminal)
```bash
git checkout main && git pull
git checkout -b feat/dispatch-health-version
# (make a visible version change, e.g. bump VERSION in services/dispatch-service/app.py)
git add services/dispatch-service/app.py
git commit -m "Bump dispatch-service /health version"
git push -u origin feat/dispatch-health-version
gh pr create --fill        # then review + merge to main
```
*Merging to `main` auto-triggers the pipeline — no manual deploy after. New commit = new SHA, so no immutable-tag collision.*

**Watch + verify (terminal):**
```bash
aws codepipeline get-pipeline-state --name devops-g1-dispatch-service-pipeline --region us-east-1 --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table   # all Succeeded
aws ecs describe-services --cluster $CL --services devops-g1-dispatch-service-svc --region us-east-1 --query 'services[0].deployments[].{status:status,taskDef:taskDefinition,running:runningCount}'   # new revision, PRIMARY
```

---

## Files this build book uses (in `aws/`)
| File | Used by |
|---|---|
| `devops-g1-dispatch-service-taskdef.json` | step 6 register-task-definition |
| `ecs-tasks-trust-policy.json` | step 3 both ECS roles |
| `ecs-exec-task-role-policy.json` | step 3 task role |
| `codebuild-trust-policy.json` / `codebuild-dispatch-policy.json` | step 12 |
| `devops-g1-dispatch-service-build.json` | step 13 create-project |
| `codepipeline-trust-policy.json` / `codepipeline-dispatch-policy.json` | step 14 |

Buildspec: `buildspecs/dispatch-service.yml` (must be on `main`).

---

## Quick teardown (Phase 6, after grading — do NOT run early)
Order matters: `pipeline → ECS service → (ALB/TG owned by P2) → cluster (P1) → SG → log group → ECR`.
```bash
aws codepipeline delete-pipeline --name devops-g1-dispatch-service-pipeline --region us-east-1
aws ecs update-service --cluster $CL --service devops-g1-dispatch-service-svc --desired-count 0 --region us-east-1
aws ecs delete-service --cluster $CL --service devops-g1-dispatch-service-svc --force --region us-east-1
aws ec2 delete-security-group --group-id sg-0ac76246a829107fc --region us-east-1
aws logs delete-log-group --log-group-name /ecs/devops-g1-dispatch-service --region us-east-1
# ECR only if instructed:
aws ecr delete-repository --repository-name devops-g1-dispatch-service --force --region us-east-1
```
**Never delete:** default VPC/subnets, another group's resources.
