# Application Load Balancer + target group (type "ip") + HTTP listener on port 80.
# Only Service A ever registers with this target group — see docs/terraform-gate1-design.md §4.
# The ALB's own security group is the thing every downstream service's ingress_source_sg_ids
# ultimately traces back to for the one legitimate public entry point.

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Public entry point. Inbound 80 from the internet only."
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from the internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To Service A app port only"
    from_port   = var.service_a_app_port
    to_port     = var.service_a_app_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # restricted precisely by the target group's SG-referenced ingress rule on Service A's side, not here
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-alb-sg"
  })
}

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-alb"
  })
}

resource "aws_lb_target_group" "service_a" {
  name        = "${var.name_prefix}-svc-a-tg"
  port        = var.service_a_app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # required: Fargate tasks have no EC2 instance to register as a target

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-svc-a-tg"
  })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service_a.arn
  }
}
