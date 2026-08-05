# infra/environments/lab

The actual workload. Wires `modules/network` + `modules/alb` + `modules/ecs-platform` + three
instances of `modules/ecs-service` (Service A/B/C) together.

This is what `plan` / `apply` / `destroy` runs against day to day. Do not create workload
resources anywhere else in this repository.

Before writing your own service instance here, read the module interface contract for
`modules/ecs-service` (variable and output names, including the security-group handshake for
the A -> B -> C -> A traffic contract) so your instance wires correctly against the others.
