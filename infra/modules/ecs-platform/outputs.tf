output "cluster_id" {
  value = aws_ecs_cluster.this.id
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_connect_namespace_arn" {
  value = aws_service_discovery_http_namespace.this.arn
}

output "execution_role_arn" {
  description = "CONFIRMED name — matches the execution_role_arn input on every modules/ecs-service instance"
  value       = aws_iam_role.execution.arn
}
