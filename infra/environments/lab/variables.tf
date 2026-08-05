# Image SHA selection lives here, at the environment level — the release owner (rotating role)
# is responsible for confirming each SHA already exists in ECR before it's set here. See
# docs/terraform-gate1-design.md §8: this Terraform selects which already-pushed SHA deploys,
# it never builds or pushes images itself.
