# infra/ — Assignment 1: Greenfield ECS Fargate via Terraform/OpenTofu

This directory builds a second, fully independent ECS cluster for Group 1, entirely from
Infrastructure as Code. It does not touch, import, or manage anything in the existing
console-built cluster (`devops-g1-cluster`, `devops-g1-alb`, `group1.internal`, or the existing
ECR repos) — see `docs/terraform-gate1-design.md` §0 for the full scope boundary.

Design reference: `docs/terraform-gate1-design.md` (Gate 1 submission).

## Layout

```
infra/
├── bootstrap/              one-time setup: S3 state backend + locking. Applied with local
│                           state, outside the remote backend it creates. Platform owner runs
│                           this first, once.
├── environments/lab/       the actual workload — wires network + alb + ecs-platform + the
│                           three service instances together. This is what `plan`/`apply` runs
│                           against day to day.
├── modules/
│   ├── network/            VPC, public/private subnets (2 AZs), route tables, VPC endpoints
│   ├── alb/                Application Load Balancer, target group (type ip)
│   ├── ecs-platform/       ECS cluster, Service Connect namespace
│   └── ecs-service/        one reusable module, instantiated three times (Service A/B/C)
└── tests/                  architecture-rules-as-code checks (see Gate 1 §8a)
```

## Build order (why this order, not another)

1. `bootstrap/` — must exist before anything else has a remote backend to write state to
2. `modules/network` — subnets must exist before the ALB or any Fargate task can be placed
3. `modules/alb` and `modules/ecs-platform` — both depend on network, not on each other; can be
   built in parallel
4. `modules/ecs-service` (three instances: A, B, C) — depends on outputs from all three modules
   above

## Ownership (Cycle 1)

| Layer | Owner |
|---|---|
| `bootstrap/`, `modules/network`, `modules/alb`, `modules/ecs-platform` | Platform owner (rotates by cycle — Meron for Cycle 1) |
| `modules/ecs-service` (the shared module itself) | Meron scaffolds first; all three service owners PR into it |
| Service A instance (`ride-api`) | Meron |
| Service B instance (`matching-service`) | Rigbe |
| Service C instance (`dispatch-service`) | Nebyat |

## Before writing your own service instance

Read the module interface contract (variable and output names for `modules/ecs-service`,
including the security-group handshake for the A→B→C→A traffic contract) before writing your
own instantiation in `environments/lab/main.tf` — the exact names have to match across all three
service owners' code for `terraform plan` to wire the dependency graph correctly.
