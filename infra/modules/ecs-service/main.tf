# Shared module instantiated once per service (A/B/C). Enforces the mandatory defaults from
# docs/terraform-gate1-design.md §8a unconditionally for every instance: CloudWatch Logs,
# ECS Exec, deployment circuit breaker + automatic rollback, and assign_public_ip hardcoded
# false — none of these are exposed as per-instance overrides.

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/devops-g1-iac-${var.service_name}"
  retention_in_days = 14

  tags = merge(var.tags, {
    Name = "/ecs/devops-g1-iac-${var.service_name}"
  })
}

data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Per-service task role. ECS Exec's SSM permissions are required unconditionally — same
# real bug hit and fixed in the prior console-built assignment (scar-log Entry 2): ECS Exec
# needs this on the TASK role, separate from the execution role's ECR-pull/logging permissions,
# even for services whose own application code makes no direct AWS API calls.
resource "aws_iam_role" "task" {
  name               = "devops-g1-iac-${var.service_name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "ecs_exec" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecs_exec" {
  name   = "ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.ecs_exec.json
}

resource "aws_security_group" "this" {
  name        = "devops-g1-iac-${var.service_name}-sg"
  description = "Inbound ${var.container_port} only from explicitly allowed security groups"
  vpc_id      = data.aws_subnet.first.vpc_id

  # Ingress/egress live in SEPARATE rule resources below, NOT inline blocks. Inline
  # rules make aws_security_group.this depend on the source SG ids, which creates a
  # Terraform dependency cycle once the C->A callback closes the A->B->C->A loop
  # (caught by `tofu validate` in Cycle 1). Separate rule resources decouple SG
  # creation from the source ids: all SGs create first, then all the rules.
  tags = merge(var.tags, {
    Name = "devops-g1-iac-${var.service_name}-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "from_source" {
  for_each                     = toset(var.ingress_source_sg_ids)
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  description                  = "Allowed source per traffic contract"

  tags = merge(var.tags, {
    Name = "devops-g1-iac-${var.service_name}-ingress"
  })
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All outbound - ECR/CloudWatch/SSM via VPC endpoints + downstream calls"

  tags = merge(var.tags, {
    Name = "devops-g1-iac-${var.service_name}-egress"
  })
}

data "aws_subnet" "first" {
  id = var.subnet_ids[0]
}

resource "aws_ecs_task_definition" "this" {
  family                   = "devops-g1-iac-${var.service_name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = var.service_name
      image     = "${var.ecr_repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          name          = var.service_name
          containerPort = var.container_port
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]

      environment = [
        for k, v in var.environment : { name = k, value = v }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = var.service_name
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -fs http://localhost:${var.container_port}/health || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
    }
  ])

  tags = var.tags
}

data "aws_region" "current" {}

resource "aws_ecs_service" "this" {
  name            = "devops-g1-iac-${var.service_name}-svc"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.this.id]
    assign_public_ip = false # hardcoded — architecture-rules-as-code rule #1, never a real override
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  service_connect_configuration {
    enabled   = true
    namespace = var.service_connect_namespace_arn

    service {
      port_name      = var.service_name
      discovery_name = var.service_name

      client_alias {
        port     = var.container_port
        dns_name = var.service_name
      }
    }
  }

  dynamic "load_balancer" {
    for_each = var.register_with_alb ? [1] : []
    content {
      target_group_arn = var.alb_target_group_arn
      container_name   = var.service_name
      container_port   = var.container_port
    }
  }

  tags = var.tags
}
