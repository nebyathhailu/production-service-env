# =============================================================================
# modules/data — RDS MySQL + the Secrets Manager secret holding its creds
#
# Service-agnostic, same as modules/service: nothing here is specific to any
# one teammate's app. Every instantiation produces its own instance, its own
# generated password, and its own secret — no credentials are ever shared
# across instantiations.
# =============================================================================

data "aws_vpc" "this" {
  id = var.vpc_id
}

# --- Credentials -------------------------------------------------------------

# Generated, never accepted as an input variable — this is what actually makes
# "the value never touches the repo, the image, or user-data" true, rather
# than just documented. Nothing ever passes this in, so nothing downstream
# (a .tfvars file, a CI log, a plan diff) can ever show it as a literal.
resource "random_password" "db" {
  length  = 24
  special = true
  # Excludes characters that commonly need escaping in shell / user-data /
  # JDBC connection strings, so nothing downstream needs bespoke quoting.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# --- Networking ----------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-data-subnets"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-data-subnets"
  })
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "Inbound MySQL (3306), scoped to the platform VPC CIDR — never 0.0.0.0/0."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-sg"
  })
}

locals {
  db_ingress_cidrs = coalesce(var.ingress_cidrs, [data.aws_vpc.this.cidr_block])
}

# Separate rule resources, not an inline ingress/egress block on the SG —
# applying the fix the team already found the hard way in modules/ecs-service
# (PR #38): an inline dynamic block ties the SG resource's own creation to
# whatever it references, which is exactly what produced a real dependency
# cycle there (A->C->B->A). This module has no cross-module SG reference
# today, but decoupling rules from the SG resource avoids the same class of
# bug if that ever changes.
resource "aws_vpc_security_group_ingress_rule" "mysql" {
  for_each = toset(local.db_ingress_cidrs)

  security_group_id = aws_security_group.db.id
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.db.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- RDS instance --------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-mysql"
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  db_name           = var.db_name
  username          = var.db_username
  password          = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  publicly_accessible = false
  skip_final_snapshot = true # lab environment — no retained snapshot on destroy

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-mysql"
  })
}

# --- Secret --------------------------------------------------------------------

resource "aws_secretsmanager_secret" "db" {
  name        = "${var.name_prefix}-db-credentials"
  description = "MySQL credential envelope for ${var.name_prefix} — resolved by the app at boot, never baked into user-data or the image."

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-credentials"
  })
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
  })
}
