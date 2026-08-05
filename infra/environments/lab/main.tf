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
