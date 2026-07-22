# Slack notifications via AWS Chatbot (Group 1)

Sends **error-log alerts**, **pipeline/deploy events**, and **ECS task/service events** into one
Slack channel. Flow: sources → SNS topic `devops-g1-notifications` → AWS Chatbot → Slack.

**Prereqs:** Slack workspace admin (to authorize the AWS Chatbot app once) · everything in us-east-1.

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=827478161993
export TOPIC_ARN=arn:aws:sns:us-east-1:827478161993:devops-g1-notifications
```

---

## Stage 1 — SNS topic + access policy (terminal)
```bash
aws sns create-topic --name devops-g1-notifications --region $AWS_REGION \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=platform-owner Key=Environment,Value=lab
aws sns set-topic-attributes --topic-arn $TOPIC_ARN --attribute-name Policy \
  --attribute-value file://aws/sns-notifications-topic-policy.json --region $AWS_REGION
```
*Creates the fan-in topic and lets EventBridge, CodeStar Notifications, and CloudWatch publish to it.*
**Verify:** `aws sns get-topic-attributes --topic-arn $TOPIC_ARN --region $AWS_REGION --query 'Attributes.Policy'`

## Stage 2 — Chatbot IAM role (terminal)
```bash
aws iam create-role --role-name devops-g1-chatbot-role \
  --assume-role-policy-document file://aws/chatbot-trust-policy.json \
  --tags Key=Project,Value=devops-mentorship Key=Group,Value=group-1 Key=Owner,Value=platform-owner Key=Environment,Value=lab
aws iam attach-role-policy --role-name devops-g1-chatbot-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess
```
*Role Chatbot assumes to render alarm/event detail in Slack (read-only).*

## Stage 3 — Authorize Slack + create the channel config (AWS Console)
> **Console:** AWS Console → **Amazon Q Developer in chat applications** (search "Chatbot") → **Configure new client → Slack → Configure**
> - This redirects to Slack → **Allow** the AWS app (needs Slack admin).
> - Back in AWS: **Configure new channel** →
>   - Name: `devops-g1-slack`
>   - Slack channel: pick the target channel (for a private channel, invite the app: `/invite @Amazon Q` in Slack first)
>   - Permissions → **Use an existing role** → `devops-g1-chatbot-role`
>   - Channel guardrail policies: `CloudWatchReadOnlyAccess`
>   - **Notifications — SNS topics:** add region us-east-1 → topic `devops-g1-notifications`
> - **Save.**

**Prereq:** Stages 1–2 done. **Why Console:** the Slack OAuth handshake can't be done by CLI.

## Stage 4 — Wire the three sources to the topic

### 4a. Error-log alerts (terminal) — example: dispatch-service
```bash
aws logs put-metric-filter --log-group-name /ecs/devops-g1-dispatch-service --region $AWS_REGION \
  --filter-name dispatch-error-lines --filter-pattern '{ $.level = "ERROR" }' \
  --metric-transformations metricName=DispatchErrors,metricNamespace=devops-g1,metricValue=1

aws cloudwatch put-metric-alarm --alarm-name devops-g1-dispatch-errors --region $AWS_REGION \
  --namespace devops-g1 --metric-name DispatchErrors --statistic Sum --period 60 \
  --evaluation-periods 1 --threshold 0 --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching --alarm-actions $TOPIC_ARN
```
*Counts JSON log lines with `level=ERROR`; alarms (→ Slack) when any appear in a 60s window. Repeat per service with its own log group + metric name.*
> Note: this posts the **alarm** ("errors > 0"), not the log line text. For the literal line, add a Lambda subscription filter (ask me).

### 4b. Pipeline / deploy events (terminal) — per pipeline
```bash
aws codestar-notifications create-notification-rule --region $AWS_REGION \
  --name devops-g1-dispatch-pipeline-notify \
  --resource arn:aws:codepipeline:us-east-1:827478161993:devops-g1-dispatch-service-pipeline \
  --detail-type FULL \
  --event-type-ids codepipeline-pipeline-pipeline-execution-succeeded codepipeline-pipeline-pipeline-execution-failed codepipeline-pipeline-pipeline-execution-canceled \
  --targets TargetType=SNS,TargetAddress=$TOPIC_ARN
```
*Posts to Slack when the pipeline succeeds/fails/cancels. Repeat with each pipeline ARN.*
> Console alt: **CodePipeline → <pipeline> → Notify → Create notification rule** → target the SNS topic.

### 4c. ECS task/service events (terminal)
```bash
aws events put-rule --name devops-g1-ecs-events --region $AWS_REGION \
  --event-pattern '{"source":["aws.ecs"],"detail-type":["ECS Task State Change","ECS Deployment State Change"]}'
aws events put-targets --rule devops-g1-ecs-events --region $AWS_REGION \
  --targets "Id"="sns","Arn"="$TOPIC_ARN"
```
*Posts task stops, deployment state changes, and circuit-breaker rollbacks to Slack.*

## Stage 5 — Test
```bash
# direct topic test (should appear in Slack)
aws sns publish --topic-arn $TOPIC_ARN --region $AWS_REGION --subject "devops-g1 test" --message "Hello from Group 1"
# ECS event test: stop a task and watch Slack
aws ecs stop-task --cluster devops-g1-cluster --task $(aws ecs list-tasks --cluster devops-g1-cluster --service-name devops-g1-dispatch-service-svc --region $AWS_REGION --query 'taskArns[0]' --output text) --region $AWS_REGION
```
**Verify:** both messages land in the Slack channel.

---

## Files used
`aws/chatbot-trust-policy.json` · `aws/sns-notifications-topic-policy.json`

## Cleanup (Phase 6)
```bash
aws events remove-targets --rule devops-g1-ecs-events --ids sns --region us-east-1
aws events delete-rule --name devops-g1-ecs-events --region us-east-1
aws codestar-notifications delete-notification-rule --arn <rule-arn> --region us-east-1
aws cloudwatch delete-alarms --alarm-names devops-g1-dispatch-errors --region us-east-1
aws sns delete-topic --topic-arn $TOPIC_ARN --region us-east-1
# delete the Chatbot channel config in the Console; then delete devops-g1-chatbot-role
```
