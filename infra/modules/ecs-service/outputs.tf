# Every instance of this module produces these — the downstream service in the traffic chain
# consumes security_group_id as part of its own ingress_source_sg_ids input.

output "security_group_id" {
  description = "Consumed by whichever service is downstream of this one in the traffic contract"
  value       = null # TODO: wire to the real aws_security_group resource once written
}

output "service_connect_discovery_name" {
  description = "Confirms Service Connect wiring matches what callers expect"
  value       = null # TODO
}

output "ecs_service_name" {
  value = null # TODO
}

output "task_definition_arn" {
  value = null # TODO
}
