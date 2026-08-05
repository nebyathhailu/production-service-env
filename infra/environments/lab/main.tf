module "network" {
  source      = "../../modules/network"
  name_prefix = "devops-g1-iac"

  tags = {
    Owner = "platform-owner"
  }
}

# modules/alb, modules/ecs-platform, and the three modules/ecs-service instances
# (Service A/B/C) are added here as each is written and reviewed. Keeping the first
# apply small and reviewable per the Gate 1 approval note — network only, for now.
