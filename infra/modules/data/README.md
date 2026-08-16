# `modules/data` — RDS MySQL + Secrets Manager

Group-owned platform module (Assignment 2). Service-agnostic so all three of us reuse it to give our own service a real managed database — nothing about a specific service is hardcoded.

## What it creates

- **`aws_db_instance.this`** — MySQL, private (`publicly_accessible = false`), sized `db.t3.micro` / 20 GiB by default, in a subnet group built from the default VPC's subnets.
- **`random_password.db`** — the master password, generated inside this module and **never accepted as an input variable**. Nothing downstream (a `.tfvars` file, a CI log, a `plan` diff) can ever show it as a literal, because nothing ever passes it in.
- **`aws_secretsmanager_secret` + `_version`** — the credential envelope (`host`, `port`, `username`, `password`, `dbname`) as JSON. `modules/service` receives only the secret's **ARN**; the app resolves the value itself at boot.
- **`aws_security_group.db`** — inbound 3306 scoped to the default VPC's CIDR (**never `0.0.0.0/0`**), using separate `aws_vpc_security_group_ingress_rule`/`egress_rule` resources rather than an inline block — see "Design decisions" below for why that specific choice matters here.

## How it satisfies the brief

- **C3 (secrets):** the password is generated, not supplied — it structurally cannot appear anywhere in the repo, an image, or user-data, because there is no code path that accepts it as a value from outside this module.
- **DB migration target:** `db_endpoint` + `db_port` give every teammate a real managed MySQL instance to point their schema/seed migration at, instead of a local container.

## Interface (contract with `modules/service`)

| Output | Consumed as |
|---|---|
| `db_endpoint` | `modules/service`'s `db_endpoint` input |
| `db_port` | `modules/service`'s `db_port` input |
| `secret_arn` | `modules/service`'s `secret_arn` input |

Names match `modules/service`'s own `variables.tf` exactly, so root wiring is a straight pass-through:

```hcl
db_endpoint = module.data.db_endpoint
db_port     = module.data.db_port
secret_arn  = module.data.secret_arn
```

## Design decisions worth a look

1. **Password is generated, never an input variable.** The obvious alternative — a `db_password` variable with `sensitive = true` — still means *something* has to supply a value from outside the module, which reopens exactly the question this assignment is testing ("where does this secret actually come from"). Generating it inside the module removes that question instead of trusting discipline to answer it correctly every time.
2. **Separate SG rule resources, not an inline block — applying PR #38's lesson.** Nebyat's `modules/ecs-service` work on the other assignment hit a real `A→C→B→A` dependency cycle because an inline `dynamic "ingress"` block tied the security group's own creation to whatever it referenced. This module has no cross-module SG reference today, but using `aws_vpc_security_group_ingress_rule`/`egress_rule` as separate resources avoids the same class of bug if that ever changes — cheap insurance for a lesson the team already paid for once.
3. **CIDR-scoped ingress, not a tight SG-to-SG reference to `modules/service`.** `modules/service` is instantiated once per teammate with no fixed identity this module could reference in advance, and its own `ingress_cidrs` already defaults to the VPC CIDR for the same reason. Matching that convention here keeps both modules independently instantiable without a required apply-order between them.

## Testing

- `tofu fmt` + `tofu validate` clean.
- **Not yet runtime-verified** (needs a LocalStack apply with an auth token): whether `db_endpoint` (`aws_db_instance.this.address`) is actually reachable from inside a `modules/service` EC2 instance without further translation, or needs the same `localhost.localstack.cloud`-style substitution `modules/service` documents for its own `aws_endpoint_url`. Flagged explicitly in `outputs.tf` rather than assumed. Tracking on first `make up`.

## Checklist

- [x] `tofu fmt` / `validate` clean
- [x] No plaintext secret anywhere in variables, outputs, or state-adjacent config (password is generated, output is ARN-only)
- [x] Ingress scoped, not `0.0.0.0/0`
- [ ] Two teammate approvals
- [ ] Runtime verification on first `make up` (in particular: `db_endpoint` reachability from inside an instance)
