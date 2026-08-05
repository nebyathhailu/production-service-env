output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_security_group_id" {
  description = "Consumed by Service A's ingress_source_sg_ids"
  value       = aws_security_group.alb.id
}

output "target_group_arn" {
  description = "Consumed by Service A's alb_target_group_arn input"
  value       = aws_lb_target_group.service_a.arn
}
