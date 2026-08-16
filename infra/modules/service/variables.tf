# =============================================================================
# modules/service — inputs
#
# Service-agnostic: every teammate reuses this module and supplies their own
# image tag, port, and start command via variables. Nothing about a specific
# service is hardcoded here.
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

# --- Image / instance ---------------------------------------------------------

variable "app_ami_id" {
  description = <<-EOT
    The AMI the instance boots. On LocalStack this is the app image CI tags as
    `localstack-ec2/app:ami-<12 hex chars>`. If the tag is not in that exact
    form you get InvalidAMIID.NotFound at apply (ASSIGNMENT.md break #2).
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,}$", var.app_ami_id)) || can(regex(":ami-[0-9a-f]{12}$", var.app_ami_id))
    error_message = "app_ami_id must be a real ami-<hex> id or a localstack-ec2 tag ending in :ami-<12 hex chars>."
  }
}

variable "instance_type" {
  description = "EC2 instance type. t3.small gives headroom for nginx + app (t3.micro is too tight)."
  type        = string
  default     = "t3.small"
}

variable "root_volume_size" {
  description = "Root EBS volume size (GiB). Must be explicit on LocalStack or the instance fails to launch."
  type        = number
  default     = 8
}

# --- App runtime --------------------------------------------------------------

variable "app_port" {
  description = "Port the app listens on inside the instance (nginx proxies to it)."
  type        = number
  default     = 3000
}

variable "app_start_command" {
  description = "Shell command user-data runs to start the app process (the image already contains it)."
  type        = string
  default     = "python app.py"
}

variable "app_workdir" {
  description = "Working directory the app starts from inside the instance image."
  type        = string
  default     = "/app"
}

variable "app_env" {
  description = <<-EOT
    Extra service-specific environment variables for the app process (e.g.
    { DISPATCH_SERVICE_PORT = "3003", BIND_HOST = "0.0.0.0" }). DB creds are NOT
    passed here — the app resolves them at boot from Secrets Manager.
  EOT
  type        = map(string)
  default     = {}
}

# NOTE: the app's memory ceiling (the 2204 OOM control, `--memory=512m`) is NOT
# set here. The app runs as a process inside the instance container, so the
# cgroup limit is applied to that container via `EC2_DOCKER_FLAGS` (set for you
# by the harness), not by this module. Declaring a var here would falsely imply
# the module enforces it.

# --- Cloud wiring (from the data module — ARN + endpoint, never the value) -----

variable "secret_arn" {
  description = "Secrets Manager ARN holding the DB credential envelope. The value never enters user-data."
  type        = string
}

variable "db_endpoint" {
  description = <<-EOT
    DB host the app connects to (host only, not host:port — pair with db_port).
    Matches the data module's `db_endpoint` output. On LocalStack, from inside
    the instance container `localhost` is the instance itself (break #1) — pass a
    bridge-reachable host such as `localhost.localstack.cloud`.
  EOT
  type        = string
}

variable "db_port" {
  description = "DB port."
  type        = number
  default     = 3306
}

variable "aws_endpoint_url" {
  description = <<-EOT
    Endpoint the app's AWS SDK targets. Points at LocalStack from inside the
    instance. On real AWS this is left unset and the SDK talks to AWS — the
    same binary, no `if (isLocalStack)` branch.
  EOT
  type        = string
  default     = "http://localhost.localstack.cloud:4566"
}

variable "aws_region" {
  description = "AWS region for the app's SDK and provider."
  type        = string
  default     = "us-east-1"
}

# --- Networking ---------------------------------------------------------------

variable "ingress_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach nginx (port 80) and the app port. Default scopes to
    the default VPC's CIDR — NEVER 0.0.0.0/0. `trivy config` flags an open
    ingress, which is exactly the deliberate red-PR change for the trivy gate.
  EOT
  type        = list(string)
  default     = null
}
