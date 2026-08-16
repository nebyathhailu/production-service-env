# =============================================================================
# modules/data — inputs
#
# Creates the RDS MySQL instance and the Secrets Manager secret holding its
# credentials. Callers (modules/service instances) receive only db_endpoint,
# db_port, and secret_arn — the password itself is never accepted as an input
# variable at all (it's generated inside this module via `random_password`),
# so it can never appear in a .tfvars file, a CI log, or a plan diff as a
# literal. That's what makes "the secret value never touches the repo" true
# by construction, not just by discipline.
# =============================================================================

variable "name_prefix" {
  description = "Prefix for names/tags of resources this module creates."
  type        = string
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}

# --- Database ------------------------------------------------------------------

variable "db_name" {
  description = "Initial database name created on the instance."
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username. Not a secret by itself — paired with a generated password that's never exposed as a variable."
  type        = string
  default     = "app"
}

variable "engine_version" {
  description = "MySQL engine version. Pinned explicitly rather than trusting a moving default — LocalStack's supported RDS versions can lag real AWS."
  type        = string
  default     = "8.0"
}

variable "instance_class" {
  description = "RDS instance class. db.t3.micro is the smallest MySQL-compatible class and enough for this lab."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20
}

# --- Networking ------------------------------------------------------------------

variable "ingress_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach MySQL (3306). Defaults to the default VPC's own
    CIDR — NEVER 0.0.0.0/0 — same convention modules/service uses for its own
    ingress_cidrs, so an app instance anywhere in the default VPC can reach
    this database without per-instance SG wiring. modules/data is
    instantiated independently per teammate, with no dependency on a specific
    modules/service instance's security group, so this is intentionally a
    CIDR default rather than a tight SG-to-SG reference.
  EOT
  type        = list(string)
  default     = null
}

variable "aws_region" {
  description = "AWS region for provider/subnet lookups."
  type        = string
  default     = "us-east-1"
}
