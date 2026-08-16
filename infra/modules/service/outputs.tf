output "instance_id" {
  description = "ID of the app EC2 instance."
  value       = aws_instance.app.id
}

output "instance_private_ip" {
  description = "Private IP of the instance (the bridge-reachable address on LocalStack)."
  value       = aws_instance.app.private_ip
}

output "app_security_group_id" {
  description = "Security group governing the instance."
  value       = aws_security_group.app.id
}

output "alb_dns_name" {
  description = "ALB DNS name (declared as IaC; nginx carries the real traffic)."
  value       = aws_lb.app.dns_name
}
