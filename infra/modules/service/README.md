# `modules/service` — EC2 + nginx + user-data + health wiring

Group-owned platform module. Runs a service's app image as a Docker-backed
LocalStack EC2 instance, fronts it with a **readiness-gated** nginx reverse
proxy, and declares the ALB topology as scanned IaC. Service-agnostic: every
teammate reuses it and supplies their own image, port, and start command.

## What it creates

| Resource | Purpose |
|---|---|
| `aws_security_group.app` | Ingress 80 + app port (scoped CIDR), egress all |
| `aws_instance.app` | Boots the app AMI; `user_data` installs nginx + starts the app |
| `aws_lb` / `aws_lb_target_group` / `aws_lb_listener` | ALB topology as IaC (graded + scanned; nginx carries real traffic) |

## Inputs

| Name | Default | Notes |
|---|---|---|
| `name_prefix` | — | Name/tag prefix |
| `app_ami_id` | — | `localstack-ec2/app:ami-<12 hex>` tag CI produces (break #2) |
| `instance_type` | `t3.small` | t3.micro is too tight for nginx + app |
| `root_volume_size` | `8` | Must be explicit on LocalStack |
| `app_port` | `3000` | Port the app listens on (dispatch-service uses `3003`) |
| `app_start_command` | `python app.py` | How user-data starts the app |
| `app_workdir` | `/app` | Where the app starts from in the image |
| `app_env` | `{}` | Extra non-secret env, e.g. `{ DISPATCH_SERVICE_PORT = "3003", BIND_HOST = "0.0.0.0" }` |
| `secret_arn` | — | Secrets Manager ARN (from `modules/data`) — **value never passed** |
| `db_endpoint` | — | DB host (host only), bridge-reachable e.g. `localhost.localstack.cloud` (break #1) |
| `db_port` | `3306` | |
| `aws_endpoint_url` | `http://localhost.localstack.cloud:4566` | SDK target; unset on real AWS |
| `aws_region` | `us-east-1` | |
| `ingress_cidrs` | default VPC CIDR | **Never `0.0.0.0/0`** — that's the trivy red-PR |

## Outputs

`instance_id`, `instance_private_ip`, `app_security_group_id`, `alb_dns_name`.

## Readiness gating (C4)

nginx gates all business traffic behind an internal `auth_request` to the app's
`/readyz`. When the app returns 503 (DB down / pool saturated / secret failed to
resolve), the gate denies the request and nginx serves a clean 503 — the app's
business routes receive no traffic. `/healthz` and `/readyz` pass straight
through so probes observe real state. Break the secret → `/readyz` flips to 503
→ business traffic stops; fix it → recovery. That flip is the C4 evidence.

## Secret discipline (C3)

`user_data` receives the secret **ARN + endpoint only**, never the value. The
app calls `GetSecretValue` at boot. `evidence/03-secrets/user-data.txt` should
show the ARN and no plaintext credential.

## LocalStack fidelity caveats (for FIDELITY.md)

- **Only the `default` security group is honoured.** `aws_security_group.app`
  governs nothing at runtime; it exists for IaC + `trivy config`. Verify real SG
  enforcement on AWS with a port scan from a disallowed source.
- **SG ingress applies only at instance creation.** Editing the SG opens no
  ports on a running instance — re-create it (break #3).
- **ELBv2 has no documented active health checking.** The `aws_lb` target group
  health check is declared but untested on LocalStack; nginx does the real
  gating. Verify target-group health-check behaviour on real AWS.
- **The Docker socket is mounted inside the instance** — a `docker run` there
  creates a sibling on the host, not a child. This module starts the app as a
  process instead, so the `--memory` ceiling comes from `EC2_DOCKER_FLAGS` on
  the instance container itself.
