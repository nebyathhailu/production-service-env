# Every instance of this module produces these — the downstream service in the traffic chain
# consumes security_group_id as part of its own ingress_source_sg_ids input.

output "security_group_id" {
  description = "Consumed by whichever service is downstream of this one in the traffic contract"
  value       = aws_security_group.this.id
}

output "service_connect_discovery_name" {
  description = "Confirms Service Connect wiring matches what callers expect"
  value       = var.service_name
}

output "ecs_service_name" {
  value = aws_ecs_service.this.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.this.arn
}
