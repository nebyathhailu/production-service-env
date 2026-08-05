# modules/ecs-service — Interface Contract

Agreed variable and output names for the shared `ecs-service` module, so Service A/B/C
instances and the platform-layer modules connect correctly in the Terraform graph. This reflects
the actual code in `infra/modules/ecs-service`, `infra/modules/ecs-platform`, and
`infra/modules/network` as of this update — treat the code as the source of truth if this doc
ever drifts.

## 1. `modules/ecs-platform` — outputs consumed by every `ecs-service` instance

| Output | Type | Source |
|---|---|---|
| `cluster_id` | string | ECS cluster |
| `cluster_name` | string | ECS cluster |
| `service_connect_namespace_arn` | string | Service Connect HTTP namespace |
| `execution_role_arn` | string | **Confirmed name** — one shared execution role (ECR pull + logging only), created once in `ecs-platform`, reused by all three services. Do not create per-service execution roles. |

## 2. `modules/network` — outputs consumed by the platform and service layers

| Output | Type |
|---|---|
| `vpc_id` | string |
| `public_subnet_ids` | list(string) |
| `private_subnet_ids` | list(string) |
| `vpc_endpoints_security_group_id` | string |

## 3. `modules/ecs-service` — input variables (one shared module, three instances)

| Variable | Type | Notes |
|---|---|---|
| `service_name` | string | e.g. `"ride-api"`, `"matching-service"`, `"dispatch-service"` |
| `container_port` | number | 3001 / 3002 / 3003 |
| `desired_count` | number | A=2, B=1, C=1 |
| `cpu` / `memory` | number | task-level sizing |
| `image_tag` | string | Git SHA; validated to reject `latest` |
| `ecr_repository_url` | string | from the **existing** repo's data source — not a resource this module creates (Gate 1 §8) |
| `cluster_id` / `cluster_name` | string | from `modules/ecs-platform` |
| `service_connect_namespace_arn` | string | from `modules/ecs-platform` |
| `subnet_ids` | list(string) | the two **private** subnet IDs from `modules/network` |
| `execution_role_arn` | string | from `modules/ecs-platform` (shared, see §1 above) |
| `task_role_arn` | string | per-service, created by each service owner's own instantiation (ECS Exec permissions differ per service's real needs) |
| `ingress_source_sg_ids` | list(string) | the SG handshake — see §5 below |
| `environment` | map(string) | **added per Nebyat's review catch** — per-service container env vars. Every service needs at least `BIND_HOST = "0.0.0.0"`. dispatch-service additionally needs `RIDE_API_URL = "http://ride-api:3001"` for the C->A callback. Set per-instance in `environments/lab/main.tf`, not hardcoded in the module. |
| `assign_public_ip` | bool | hardcoded `false` inside the module — not a real override |
| `register_with_alb` | bool | `true` only for Service A |
| `alb_target_group_arn` | string, optional | required when `register_with_alb = true` |
| `tags` | map(string) | merged with required Project/Group/Owner/Environment tags |

## 4. `modules/ecs-service` — outputs (every instance produces these)

| Output | Used by |
|---|---|
| `security_group_id` | whichever downstream service needs to allow this one in |
| `service_connect_discovery_name` | confirms Service Connect wiring |
| `ecs_service_name` | evidence/verification commands |
| `task_definition_arn` | evidence/verification commands |

## 5. The security-group handshake (Meron ⇄ Rigbe ⇄ Nebyat)

Per Gate 1 §4 (A→B→C plus the C→A callback):

- Service C (Nebyat) outputs `security_group_id` → Service A (Meron) includes it in its
  `ingress_source_sg_ids` (the callback rule)
- Service B (Rigbe) outputs `security_group_id` → Service C (Nebyat) includes it in its
  `ingress_source_sg_ids`
- Service A (Meron) outputs `security_group_id` → Service B (Rigbe) includes it in its
  `ingress_source_sg_ids`
- The ALB module's SG output is also included in Service A's `ingress_source_sg_ids`

## 6. The `environment` map per service (resolves Nebyat's review gap)

| Service | `environment` |
|---|---|
| Service A (ride-api) | `{ BIND_HOST = "0.0.0.0" }` |
| Service B (matching-service) | `{ BIND_HOST = "0.0.0.0" }` |
| Service C (dispatch-service) | `{ BIND_HOST = "0.0.0.0", RIDE_API_URL = "http://ride-api:3001" }` |

Since this whole environment lives inside one shared VPC/Service Connect namespace, the plain
Service Connect name (`ride-api`) resolves correctly without needing the full namespace suffix —
same pattern as the existing console-built environment.

## 7. Repo scaffolding

```
infra/
├── bootstrap/                  Meron, applied once (done — real S3 backend exists)
├── environments/lab/           wires everything together; one root module, one state
├── modules/
│   ├── network/                done — real VPC/subnets/endpoints applied
│   ├── alb/                    not yet written
│   ├── ecs-platform/           written, not yet applied (cluster, namespace, execution role)
│   └── ecs-service/            written, not yet applied; shared module for A/B/C
└── tests/
    └── check-no-existing-resources.sh   pre-apply safety check, real and working
```

## Status

- [x] Bootstrap stack applied — real S3 state bucket exists
- [x] `modules/network` applied — real VPC, 4 subnets, route tables, 7 VPC endpoints exist
- [x] `execution_role_arn` output confirmed and wired into `modules/ecs-platform`
- [x] `environment` input added to `modules/ecs-service` (Nebyat's review catch)
- [ ] `modules/alb` — not yet written
- [ ] `modules/ecs-platform` applied — written, plan not yet run
- [ ] Each service owner writes their own `ecs-service` instance in `environments/lab/main.tf`
      once `alb` and `ecs-platform` are applied (their outputs are real inputs, not just names)
