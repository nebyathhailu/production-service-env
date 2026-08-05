module "network" {
  source      = "../../modules/network"
  name_prefix = "devops-g1-iac"

  tags = {
    Owner = "platform-owner"
  }
}

module "ecs_platform" {
  source         = "../../modules/ecs-platform"
  name_prefix    = "devops-g1-iac"
  namespace_name = "devops-g1-iac.internal" # verified live, no naming collision — see Gate 1 doc §5 checklist
  vpc_id         = module.network.vpc_id

  tags = {
    Owner = "platform-owner"
  }
}

module "alb" {
  source             = "../../modules/alb"
  name_prefix        = "devops-g1-iac"
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  service_a_app_port = 3001 # ride-api

  tags = {
    Owner = "platform-owner"
  }
}

# The three modules/ecs-service instances (Service A/B/C) are added here once each service
# owner's instantiation is ready — this keeps the first apply small and reviewable, per the
# Gate 1 approval note, and lets Rigbe/Nebyat PR their own instances independently.

# Existing, shared ECR repository — read-only. This assignment's Terraform never creates,
# modifies, or deletes any of the three existing repos. See docs/terraform-gate1-design.md §8
# for the full reasoning and the (a)-vs-(b) decision this resolved.
data "aws_ecr_repository" "ride_api" {
  name = "devops-g1-ride-api"
}

variable "service_a_image_tag" {
  description = "Git-SHA-tagged image already pushed to the existing devops-g1-ride-api repo by its existing CI pipeline"
  type        = string
}

module "service_a_ride_api" {
  source = "../../modules/ecs-service"

  service_name   = "ride-api"
  container_port = 3001
  desired_count  = 2 # only publicly reachable service — needs a live standby (Gate 1 §1)
  cpu            = 256
  memory         = 512

  image_tag          = var.service_a_image_tag
  ecr_repository_url = data.aws_ecr_repository.ride_api.repository_url

  cluster_id                    = module.ecs_platform.cluster_id
  cluster_name                  = module.ecs_platform.cluster_name
  service_connect_namespace_arn = module.ecs_platform.service_connect_namespace_arn
  execution_role_arn            = module.ecs_platform.execution_role_arn

  subnet_ids = module.network.private_subnet_ids

  environment = {
    BIND_HOST = "0.0.0.0"
  }

  # ALB's SG is the public entry point; Service C's SG covers the C->A callback leg
  # (docs/terraform-gate1-design.md §4). Service C isn't written yet, so this list currently
  # has just the ALB — Nebyat's SG output gets added here once his instance exists.
  ingress_source_sg_ids = [module.alb.alb_security_group_id]

  register_with_alb    = true
  alb_target_group_arn = module.alb.target_group_arn

  tags = {
    Owner = "service-a-owner"
  }
}

# Existing, shared ECR repository — read-only, same reasoning as ride-api's data source above.
data "aws_ecr_repository" "matching_service" {
  name = "devops-g1-matching-service"
}

variable "service_b_image_tag" {
  description = "Git-SHA-tagged image already pushed to the existing devops-g1-matching-service repo by its existing CI pipeline"
  type        = string
}

module "service_b_matching_service" {
  source = "../../modules/ecs-service"

  service_name   = "matching-service"
  container_port = 3002
  desired_count  = 1
  cpu            = 256
  memory         = 512

  image_tag          = var.service_b_image_tag
  ecr_repository_url = data.aws_ecr_repository.matching_service.repository_url

  cluster_id                    = module.ecs_platform.cluster_id
  cluster_name                  = module.ecs_platform.cluster_name
  service_connect_namespace_arn = module.ecs_platform.service_connect_namespace_arn
  execution_role_arn            = module.ecs_platform.execution_role_arn

  subnet_ids = module.network.private_subnet_ids

  environment = {
    BIND_HOST = "0.0.0.0"
    # App default falls back to "dispatch-service.internal:3003", which the Service Connect
    # discovery name (bare "dispatch-service") does not match — must be set explicitly or
    # this hits the exact DNS-resolution scar already documented from the console build.
    DISPATCH_SERVICE_URL = "http://dispatch-service:3003"
  }

  # Service B only accepts traffic from Service A, per the traffic contract (Gate 1 §4).
  ingress_source_sg_ids = [module.service_a_ride_api.security_group_id]

  tags = {
    Owner = "service-b-owner"
  }
}
