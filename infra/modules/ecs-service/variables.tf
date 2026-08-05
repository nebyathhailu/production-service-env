# Shared module — instantiated once per service (A/B/C).
# See docs/terraform-gate1-design.md §4 and §8a for the traffic-contract and rule reasoning
# behind these inputs. Do not add per-instance overrides for the hardcoded-false items below —
# they are architecture-rules-as-code guardrails, not configuration knobs.

variable "service_name" {
  description = "e.g. \"ride-api\", \"matching-service\", \"dispatch-service\""
  type        = string
}

variable "container_port" {
  description = "The application's own listening port (3001 / 3002 / 3003)"
  type        = number
}

variable "desired_count" {
  description = "A=2, B=1, C=1 per Gate 1 design"
  type        = number
}

variable "cpu" {
  type = number
}

variable "memory" {
  type = number
}

variable "image_tag" {
  description = "Git commit SHA. Must not be \"latest\" — enforced by validation below."
  type        = string

  validation {
    condition     = var.image_tag != "latest" && can(regex("^[0-9a-f]{7,40}", var.image_tag))
    error_message = "image_tag must be a Git SHA (7-40 hex chars), never the literal string \"latest\"."
  }
}

variable "ecr_repository_url" {
  description = "URL of the EXISTING ECR repo (read via data source, not created by this module — see Gate 1 §8)"
  type        = string
}

variable "cluster_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "service_connect_namespace_arn" {
  type = string
}

variable "subnet_ids" {
  description = "The two private-app subnet IDs from modules/network"
  type        = list(string)
}

variable "execution_role_arn" {
  type = string
}

variable "ingress_source_sg_ids" {
  description = <<-EOT
    Security-group IDs allowed to reach this service's container_port. This is the
    cross-service handshake variable — see docs/terraform-gate1-design.md §4:
      Service A: [alb_sg_id, service_c_sg_id]   (public ALB + the C->A callback leg)
      Service B: [service_a_sg_id]
      Service C: [service_b_sg_id]
  EOT
  type        = list(string)
}

variable "environment" {
  description = <<-EOT
    Per-service container environment variables, as a map(string). Every service needs at
    least BIND_HOST=0.0.0.0. Cross-service URLs go here too, e.g. dispatch-service needs
    RIDE_API_URL=http://ride-api:3001 for the C->A callback (Gate 1 §4). Each service owner
    sets this in their own environments/lab instantiation — the module does not hardcode any
    service-specific values.
  EOT
  type        = map(string)
  default     = {}
}

variable "register_with_alb" {
  description = "true only for Service A"
  type        = bool
  default     = false
}

variable "alb_target_group_arn" {
  description = "Required when register_with_alb = true"
  type        = string
  default     = null
}

variable "tags" {
  description = "Merged with the module's own required tags (Project/Group/Owner/Environment)"
  type        = map(string)
  default     = {}
}
