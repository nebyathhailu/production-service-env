# =============================================================================
# Service C — dispatch-service instantiation of the shared ecs-service module
# Owner: Nebyat (Service C owner)
#
# The module creates the SG (+ inbound rules from ingress_source_sg_ids), the
# task role (with ssmmessages/ECS Exec), the log group, task definition, and
# ECS service internally. This file only supplies per-service inputs.
# =============================================================================

# Existing, shared ECR repo — read-only (Gate 1 §8: never managed by this build).
data "aws_ecr_repository" "dispatch_service" {
  name = "devops-g1-dispatch-service"
}

variable "service_c_image_tag" {
  description = "Git-SHA image already pushed to the existing devops-g1-dispatch-service repo by its CI pipeline"
  type        = string
}

module "service_c_dispatch" {
  source = "../../modules/ecs-service"

  service_name   = "dispatch-service"
  container_port = 3003
  desired_count  = 1
  cpu            = 256
  memory         = 512

  image_tag          = var.service_c_image_tag
  ecr_repository_url = data.aws_ecr_repository.dispatch_service.repository_url

  cluster_id                    = module.ecs_platform.cluster_id
  cluster_name                  = module.ecs_platform.cluster_name
  service_connect_namespace_arn = module.ecs_platform.service_connect_namespace_arn
  execution_role_arn            = module.ecs_platform.execution_role_arn

  subnet_ids = module.network.private_subnet_ids

  environment = {
    BIND_HOST = "0.0.0.0"
    # C->A callback target, by Service Connect name. The app default is
    # "ride-api.internal:3001", which the bare discovery name "ride-api" does not
    # match — must be set explicitly or it hits the documented DNS-resolution scar.
    RIDE_API_URL = "http://ride-api:3001"
  }

  # Service C only accepts traffic from Service B (matching-service), per Gate 1 §4.
  ingress_source_sg_ids = [module.service_b_matching_service.security_group_id]

  tags = {
    Owner = "service-c-owner"
  }
}
