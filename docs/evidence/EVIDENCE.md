# Proof Pack — captured evidence

Account `240462142849` · region `us-east-1` · profile `devops-lab-new`  

Commands below were run as shown. Output is pasted as returned (trimmed only where a stream was mostly Jaeger retry noise).

---

## 1. Who we authenticated as

```console
$ aws sts get-caller-identity --profile devops-lab-new --region us-east-1 --output json
{
    "UserId": "AROATP7FJDWATPY2JP3WA:nebyathhailu@gmail.com",
    "Account": "240462142849",
    "Arn": "arn:aws:sts::240462142849:assumed-role/AWSReservedSSO_DevOpsCohort-group1-us-east-1_0da1d6c0876332bd/nebyathhailu@gmail.com"
}
```

---

## 2. All three ECS services running

```console
$ aws ecs describe-services --cluster devops-g1-iac-cluster \
    --services devops-g1-iac-ride-api-svc devops-g1-iac-matching-service-svc devops-g1-iac-dispatch-service-svc \
    --profile devops-lab-new --region us-east-1 \
    --query 'services[].{name:serviceName,status:status,desired:desiredCount,running:runningCount,taskDef:taskDefinition}'
[
    {
        "name": "devops-g1-iac-ride-api-svc",
        "status": "ACTIVE",
        "desired": 2,
        "running": 2,
        "taskDef": "arn:aws:ecs:us-east-1:240462142849:task-definition/devops-g1-iac-ride-api:2"
    },
    {
        "name": "devops-g1-iac-matching-service-svc",
        "status": "ACTIVE",
        "desired": 1,
        "running": 1,
        "taskDef": "arn:aws:ecs:us-east-1:240462142849:task-definition/devops-g1-iac-matching-service:1"
    },
    {
        "name": "devops-g1-iac-dispatch-service-svc",
        "status": "ACTIVE",
        "desired": 1,
        "running": 1,
        "taskDef": "arn:aws:ecs:us-east-1:240462142849:task-definition/devops-g1-iac-dispatch-service:1"
    }
]
```

---

## 3. Task definitions — SHA images, never `latest`

```console
$ aws ecs describe-task-definition --task-definition devops-g1-iac-ride-api \
    --profile devops-lab-new --region us-east-1 \
    --query 'taskDefinition.{family:family,revision:revision,image:containerDefinitions[0].image,env:containerDefinitions[0].environment}'
{
    "family": "devops-g1-iac-ride-api",
    "revision": 2,
    "image": "240462142849.dkr.ecr.us-east-1.amazonaws.com/devops-g1-ride-api:15e1aea-amd64",
    "env": [
        { "name": "BIND_HOST", "value": "0.0.0.0" },
        { "name": "MATCHING_SERVICE_URL", "value": "http://matching-service:3002" }
    ]
}

$ aws ecs describe-task-definition --task-definition devops-g1-iac-matching-service \
    --profile devops-lab-new --region us-east-1 \
    --query 'taskDefinition.{family:family,revision:revision,image:containerDefinitions[0].image,env:containerDefinitions[0].environment}'
{
    "family": "devops-g1-iac-matching-service",
    "revision": 1,
    "image": "240462142849.dkr.ecr.us-east-1.amazonaws.com/devops-g1-matching-service:f4d49be-amd64",
    "env": [
        { "name": "BIND_HOST", "value": "0.0.0.0" },
        { "name": "DISPATCH_SERVICE_URL", "value": "http://dispatch-service:3003" }
    ]
}

$ aws ecs describe-task-definition --task-definition devops-g1-iac-dispatch-service \
    --profile devops-lab-new --region us-east-1 \
    --query 'taskDefinition.{family:family,revision:revision,image:containerDefinitions[0].image,env:containerDefinitions[0].environment}'
{
    "family": "devops-g1-iac-dispatch-service",
    "revision": 1,
    "image": "240462142849.dkr.ecr.us-east-1.amazonaws.com/devops-g1-dispatch-service:570e4ab",
    "env": [
        { "name": "BIND_HOST", "value": "0.0.0.0" },
        { "name": "RIDE_API_URL", "value": "http://ride-api:3001" }
    ]
}
```

```console
$ aws ecr describe-images --repository-name devops-g1-ride-api \
    --profile devops-lab-new --region us-east-1 \
    --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].imageTags' --output text
15e1aea-amd64

$ aws ecr describe-images --repository-name devops-g1-matching-service \
    --profile devops-lab-new --region us-east-1 \
    --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].imageTags' --output text
f4d49be-amd64

$ aws ecr describe-images --repository-name devops-g1-dispatch-service \
    --profile devops-lab-new --region us-east-1 \
    --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].imageTags' --output text
570e4ab
```

---

## 4. ALB target health (ride-api only, both AZs)

```console
$ aws elbv2 describe-load-balancers --names devops-g1-iac-alb \
    --profile devops-lab-new --region us-east-1 \
    --query 'LoadBalancers[].{dns:DNSName,state:State.Code,scheme:Scheme}'
[
    {
        "dns": "devops-g1-iac-alb-207582331.us-east-1.elb.amazonaws.com",
        "state": "active",
        "scheme": "internet-facing"
    }
]

$ aws elbv2 describe-target-health \
    --target-group-arn arn:aws:elasticloadbalancing:us-east-1:240462142849:targetgroup/devops-g1-iac-svc-a-tg/c7824e41caf89c3e \
    --profile devops-lab-new --region us-east-1
{
    "TargetHealthDescriptions": [
        {
            "Target": {
                "Id": "10.1.11.157",
                "Port": 3001,
                "AvailabilityZone": "us-east-1b"
            },
            "HealthCheckPort": "3001",
            "TargetHealth": {
                "State": "healthy"
            },
            "AdministrativeOverride": {
                "State": "no_override",
                "Reason": "AdministrativeOverride.NoOverride",
                "Description": "No override is currently active on target"
            }
        },
        {
            "Target": {
                "Id": "10.1.10.10",
                "Port": 3001,
                "AvailabilityZone": "us-east-1a"
            },
            "HealthCheckPort": "3001",
            "TargetHealth": {
                "State": "healthy"
            },
            "AdministrativeOverride": {
                "State": "no_override",
                "Reason": "AdministrativeOverride.NoOverride",
                "Description": "No override is currently active on target"
            }
        }
    ]
}
```

---

## 5. Public request path through the ALB

```console
$ curl -sS -i --max-time 15 http://devops-g1-iac-alb-207582331.us-east-1.elb.amazonaws.com/health
HTTP/1.1 200 OK
Date: Fri, 28 Aug 2026 14:29:51 GMT
Content-Type: application/json
Content-Length: 140
Connection: keep-alive
server: envoy
x-request-id: 7ca92d47-09c9-43d7-82c5-c2d08c3c34bd
x-envoy-upstream-service-time: 13

{"dependencies":{"matching-service":"ok"},"message":"Hello ride-api listening on 3001","port":3001,"service":"ride-api","status":"healthy"}

$ curl -sS -i --max-time 20 -X POST http://devops-g1-iac-alb-207582331.us-east-1.elb.amazonaws.com/request-ride \
    -H "Content-Type: application/json" \
    -H "X-Request-ID: SUBMIT-TRACE-001" \
    -d '{"rider":"submit"}'
HTTP/1.1 200 OK
Date: Fri, 28 Aug 2026 14:29:52 GMT
Content-Type: application/json
Content-Length: 96
Connection: keep-alive
server: envoy
x-request-id: SUBMIT-TRACE-001
x-envoy-upstream-service-time: 22

{"message":"Request completed successfully","request_id":"SUBMIT-TRACE-001","status":"success"}
```

---

## 6. Same `request_id` on all three services (including C→A callback)

```console
$ aws logs tail /ecs/devops-g1-iac-ride-api --since 10m --profile devops-lab-new --region us-east-1 | grep SUBMIT-TRACE-001
2026-08-28T14:29:52.439000+00:00 ride-api/ride-api/e2d4848f16b24534a7ce46faf7aa2ee8 {"timestamp": "2026-08-28T14:29:52Z", "service": "ride-api", "level": "INFO", "event": "request_received", "request_id": "SUBMIT-TRACE-001", "path": "/request-ride", "status": 200, "trace_id": "5a562ccdc74e382eb153c9e5661148b7", "method": "POST", "client_ip": "41.139.134.147"}
2026-08-28T14:29:52.453000+00:00 ride-api/ride-api/8245dab75be149ffb8dbb0529e9c8b3a {"timestamp": "2026-08-28T14:29:52Z", "service": "ride-api", "level": "INFO", "event": "callback_received", "request_id": "SUBMIT-TRACE-001", "path": "/driver-assigned", "status": 200, "trace_id": "5a562ccdc74e382eb153c9e5661148b7", "source_service": "dispatch-service", "message": "Greeting processed", "duration_ms": 0.15}
2026-08-28T14:29:52.460000+00:00 ride-api/ride-api/e2d4848f16b24534a7ce46faf7aa2ee8 {"timestamp": "2026-08-28T14:29:52Z", "service": "ride-api", "level": "INFO", "event": "request_forwarded", "request_id": "SUBMIT-TRACE-001", "path": "/request-ride", "status": 200, "trace_id": "5a562ccdc74e382eb153c9e5661148b7", "method": "POST", "target": "matching-service", "duration_ms": 20.88}

$ aws logs tail /ecs/devops-g1-iac-matching-service --since 10m --profile devops-lab-new --region us-east-1 | grep SUBMIT-TRACE-001
2026-08-28T14:29:52.443000+00:00 matching-service/matching-service/09b33a3974ff48ff9e93fef32f120b5f {"timestamp": "2026-08-28T14:29:52Z", "service": "matching-service", "level": "INFO", "event": "request_received", "request_id": "SUBMIT-TRACE-001", "path": "/find-driver", "status": 200, "trace_id": "5a562ccdc74e382eb153c9e5661148b7", "method": "GET", "client_ip": "127.0.0.1"}
2026-08-28T14:29:52.458000+00:00 matching-service/matching-service/09b33a3974ff48ff9e93fef32f120b5f {"timestamp": "2026-08-28T14:29:52Z", "service": "matching-service", "level": "INFO", "event": "request_forwarded", "request_id": "SUBMIT-TRACE-001", "path": "/find-driver", "status": 200, "trace_id": "5a562ccdc74e382eb153c9e5661148b7", "method": "GET", "target": "dispatch-service", "downstream_status": 200, "duration_ms": 14.83}

$ aws logs tail /ecs/devops-g1-iac-dispatch-service --since 10m --profile devops-lab-new --region us-east-1 | grep SUBMIT-TRACE-001
2026-08-28T14:29:52.447000+00:00 dispatch-service/dispatch-service/0f51491d04aa42768da85c4c1b121b65 {"timestamp": "2026-08-28T14:29:52Z", "service": "dispatch-service", "level": "INFO", "event": "request_received", "request_id": "SUBMIT-TRACE-001", "path": "/assign-driver", "status": 200, "trace_id": "5a562ccdc74e382eb153c9e5661148b7", "method": "GET", "client_ip": "127.0.0.1"}
2026-08-28T14:29:52.456000+00:00 dispatch-service/dispatch-service/0f51491d04aa42768da85c4c1b121b65 {"timestamp": "2026-08-28T14:29:52Z", "service": "dispatch-service", "level": "INFO", "event": "callback_sent", "request_id": "SUBMIT-TRACE-001", "path": "/assign-driver", "status": 200, "trace_id": "5a562ccdc74e382eb153c9e5661148b7", "method": "GET", "target": "ride-api", "downstream_status": 200, "duration_ms": 8.58}
```

Hop order by timestamp: ride-api `/request-ride` → matching `/find-driver` → dispatch `/assign-driver` → ride-api `/driver-assigned` (callback) → matching forwarded 200 → ride-api forwarded 200.

---

## 7. Security groups — reference sources, not CIDRs on app ports

```console
$ aws ec2 describe-security-groups --profile devops-lab-new --region us-east-1 \
    --filters "Name=group-name,Values=devops-g1-iac-*" \
    --query 'SecurityGroups[].{Name:GroupName,Id:GroupId}' --output table
---------------------------------------------------------------
|                   DescribeSecurityGroups                    |
+-----------------------+-------------------------------------+
|          Id           |                Name                 |
+-----------------------+-------------------------------------+
|  sg-04cb87c3a8a99573d |  devops-g1-iac-ride-api-sg          |
|  sg-05d06e8ca1b8d94ce |  devops-g1-iac-matching-service-sg  |
|  sg-07b992f7224a76e9a |  devops-g1-iac-dispatch-service-sg  |
|  sg-0333a8fc33908f83d |  devops-g1-iac-alb-sg               |
|  sg-0c4a6b74376cd300c |  devops-g1-iac-vpce-sg              |
+-----------------------+-------------------------------------+

$ aws ec2 describe-security-groups --profile devops-lab-new --region us-east-1 \
    --filters "Name=group-name,Values=devops-g1-iac-alb-sg" \
    --query 'SecurityGroups[0].IpPermissions'
[
    {
        "IpProtocol": "tcp",
        "FromPort": 80,
        "ToPort": 80,
        "UserIdGroupPairs": [],
        "IpRanges": [
            {
                "Description": "HTTP from the internet",
                "CidrIp": "0.0.0.0/0"
            }
        ],
        "Ipv6Ranges": [],
        "PrefixListIds": []
    }
]

$ aws ec2 describe-security-groups --profile devops-lab-new --region us-east-1 \
    --filters "Name=group-name,Values=devops-g1-iac-ride-api-sg" \
    --query 'SecurityGroups[0].IpPermissions'
[
    {
        "IpProtocol": "tcp",
        "FromPort": 3001,
        "ToPort": 3001,
        "UserIdGroupPairs": [
            {
                "Description": "Allowed source per traffic contract",
                "UserId": "240462142849",
                "GroupId": "sg-07b992f7224a76e9a"
            },
            {
                "Description": "Allowed source per traffic contract",
                "UserId": "240462142849",
                "GroupId": "sg-0333a8fc33908f83d"
            }
        ],
        "IpRanges": [],
        "Ipv6Ranges": [],
        "PrefixListIds": []
    }
]

$ aws ec2 describe-security-groups --profile devops-lab-new --region us-east-1 \
    --filters "Name=group-name,Values=devops-g1-iac-matching-service-sg" \
    --query 'SecurityGroups[0].IpPermissions'
[
    {
        "IpProtocol": "tcp",
        "FromPort": 3002,
        "ToPort": 3002,
        "UserIdGroupPairs": [
            {
                "Description": "Allowed source per traffic contract",
                "UserId": "240462142849",
                "GroupId": "sg-04cb87c3a8a99573d"
            }
        ],
        "IpRanges": [],
        "Ipv6Ranges": [],
        "PrefixListIds": []
    }
]

$ aws ec2 describe-security-groups --profile devops-lab-new --region us-east-1 \
    --filters "Name=group-name,Values=devops-g1-iac-dispatch-service-sg" \
    --query 'SecurityGroups[0].IpPermissions'
[
    {
        "IpProtocol": "tcp",
        "FromPort": 3003,
        "ToPort": 3003,
        "UserIdGroupPairs": [
            {
                "Description": "Allowed source per traffic contract",
                "UserId": "240462142849",
                "GroupId": "sg-05d06e8ca1b8d94ce"
            }
        ],
        "IpRanges": [],
        "Ipv6Ranges": [],
        "PrefixListIds": []
    }
]
```

Read-out of the JSON: ALB :80 from `0.0.0.0/0`. ride-api :3001 from ALB SG + dispatch SG (callback). matching :3002 from ride-api SG only. dispatch :3003 from matching SG only. No `0.0.0.0/0` on 3001/3002/3003. No ride-api → dispatch ingress rule.

---

## 8. GitHub Actions OIDC (no long-lived keys)

```console
$ aws iam list-open-id-connect-providers --profile devops-lab-new
{
    "OpenIDConnectProviderList": [
        {
            "Arn": "arn:aws:iam::240462142849:oidc-provider/token.actions.githubusercontent.com"
        }
    ]
}

$ aws iam get-role --role-name devops-g1-github-actions-role --profile devops-lab-new \
    --query 'Role.{Arn:Arn,CreateDate:CreateDate}'
{
    "Arn": "arn:aws:iam::240462142849:role/devops-g1-github-actions-role",
    "CreateDate": "2026-08-28T06:15:58+00:00"
}

$ aws iam get-role-policy --role-name devops-g1-github-actions-role \
    --policy-name devops-g1-github-actions-permissions --profile devops-lab-new
{
    "RoleName": "devops-g1-github-actions-role",
    "PolicyName": "devops-g1-github-actions-permissions",
    "PolicyDocument": {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "EcrAuth",
                "Effect": "Allow",
                "Action": "ecr:GetAuthorizationToken",
                "Resource": "*"
            },
            {
                "Sid": "EcrPush",
                "Effect": "Allow",
                "Action": [
                    "ecr:BatchCheckLayerAvailability",
                    "ecr:GetDownloadUrlForLayer",
                    "ecr:BatchGetImage",
                    "ecr:PutImage",
                    "ecr:InitiateLayerUpload",
                    "ecr:UploadLayerPart",
                    "ecr:CompleteLayerUpload"
                ],
                "Resource": [
                    "arn:aws:ecr:us-east-1:240462142849:repository/devops-g1-ride-api",
                    "arn:aws:ecr:us-east-1:240462142849:repository/devops-g1-matching-service",
                    "arn:aws:ecr:us-east-1:240462142849:repository/devops-g1-dispatch-service"
                ]
            },
            {
                "Sid": "EcsDeploy",
                "Effect": "Allow",
                "Action": [
                    "ecs:DescribeServices",
                    "ecs:DescribeTaskDefinition",
                    "ecs:RegisterTaskDefinition",
                    "ecs:UpdateService"
                ],
                "Resource": "*"
            },
            {
                "Sid": "PassEcsRoles",
                "Effect": "Allow",
                "Action": "iam:PassRole",
                "Resource": [
                    "arn:aws:iam::240462142849:role/devops-g1-iac-ecs-execution-role",
                    "arn:aws:iam::240462142849:role/devops-g1-iac-ride-api-task-role",
                    "arn:aws:iam::240462142849:role/devops-g1-iac-matching-service-task-role",
                    "arn:aws:iam::240462142849:role/devops-g1-iac-dispatch-service-task-role"
                ]
            }
        ]
    }
}
```

GitHub repo variable `AWS_ACCOUNT_ID` was set to `240462142849` (`gh variable list` showed `AWS_ACCOUNT_ID	240462142849	2026-08-28T06:20:38Z`).
