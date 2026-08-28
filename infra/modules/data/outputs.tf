# =============================================================================
# modules/data — outputs
#
# db_endpoint and secret_arn are the two names modules/service's own inputs
# expect verbatim (infra/modules/service/variables.tf) — that's the entire
# contract between the two modules, and it's interface-only: neither module
# references the other's resources directly.
# =============================================================================

output "db_endpoint" {
  description = <<-EOT
    DB host only (no port) — matches modules/service's db_endpoint input name
    exactly. NOT YET RUNTIME-VERIFIED as reachable from inside an EC2 instance
    container: modules/service's own README flags the same LocalStack quirk
    ("fidelity break #1") for its own bridge-hostname handling — from inside
    an instance, plain `localhost` resolves to the instance itself, not to
    LocalStack's services. aws_db_instance.this.address is the correct
    Terraform attribute for a bare host, but whether LocalStack's RDS
    emulation already returns something bridge-reachable from another
    emulated instance, or needs an explicit localhost.localstack.cloud
    substitution the way modules/service's aws_endpoint_url does, is
    unconfirmed until this is actually applied and tested end-to-end.
  EOT
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "DB port — matches modules/service's db_port default (3306)."
  value       = aws_db_instance.this.port
}

output "secret_arn" {
  description = "Secrets Manager ARN holding the credential envelope — matches modules/service's secret_arn input exactly. The secret VALUE is never output here, only the ARN."
  value       = aws_secretsmanager_secret.db.arn
}
