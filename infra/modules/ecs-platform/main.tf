# ECS cluster, Service Connect namespace, and the ONE shared execution role every ecs-service
# instance uses (execution role only needs ECR-pull + logging permissions — no reason to create
# three separate copies of an identical role). Per-service TASK roles (ECS Exec permissions,
# etc.) are created inside modules/ecs-service itself, per instance, since those differ per
# service. See docs/terraform-gate1-design.md §1 ownership map.

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-cluster"
  })
}

resource "aws_service_discovery_http_namespace" "this" {
  name = var.namespace_name

  tags = merge(var.tags, {
    Name = var.namespace_name
  })
}

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
