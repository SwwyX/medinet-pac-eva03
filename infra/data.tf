# --- Registro de imágenes ---
resource "aws_ecr_repository" "pac" {
  name                 = var.project
  image_tag_mutability = "IMMUTABLE" # un tag (sha del commit) nunca se reescribe
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }
}

resource "aws_ecr_lifecycle_policy" "pac" {
  repository = aws_ecr_repository.pac.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar las ultimas 10 imagenes"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# --- Secretos generados por Terraform (nunca escritos en el repositorio) ---
# Quedan cifrados con la llave KMS del módulo. El estado de Terraform los
# contiene, por eso terraform.tfstate está en .gitignore.
resource "random_password" "api_db" {
  length  = 40
  special = false
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "api_db_password" {
  name   = "/${var.project}/db/api_password"
  type   = "SecureString"
  key_id = aws_kms_key.main.arn
  value  = random_password.api_db.result
}

# Secreto compartido con el módulo IAM para verificar sus JWT (HS256).
resource "aws_ssm_parameter" "jwt_secret" {
  name   = "/${var.project}/jwt/secret"
  type   = "SecureString"
  key_id = aws_kms_key.main.arn
  value  = random_password.jwt.result
}

# El pipeline actualiza este valor con el sha de la imagen a desplegar.
resource "aws_ssm_parameter" "image_tag" {
  name   = "/${var.project}/app/image_tag"
  type   = "SecureString"
  key_id = aws_kms_key.main.arn
  value  = "none"
  lifecycle {
    ignore_changes = [value]
  }
}

# --- Amazon RDS PostgreSQL ---
resource "aws_db_subnet_group" "pac" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.db[*].id # 2 AZs (DB Subnet Group Multi-AZ)
}

resource "aws_db_parameter_group" "pac" {
  name   = "${local.name}-pg${var.db_engine_version}"
  family = "postgres${var.db_engine_version}"
  # Rechaza cualquier conexión sin TLS (cifrado en tránsito obligatorio).
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
}

resource "aws_db_instance" "pac" {
  identifier                          = "${local.name}-db"
  engine                              = "postgres"
  engine_version                      = var.db_engine_version
  instance_class                      = var.db_instance_class
  allocated_storage                   = 20
  storage_type                        = "gp3"
  db_name                             = "pac"
  username                            = "pacadmin"
  manage_master_user_password         = true # contraseña maestra generada y guardada por AWS en Secrets Manager
  master_user_secret_kms_key_id       = aws_kms_key.main.arn
  db_subnet_group_name                = aws_db_subnet_group.pac.name
  parameter_group_name                = aws_db_parameter_group.pac.name
  vpc_security_group_ids              = [aws_security_group.db.id]
  publicly_accessible                 = true # DEMO: configuracion insegura a proposito, Checkov debe bloquearla
  multi_az                            = var.db_multi_az
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.main.arn
  backup_retention_period             = var.db_backup_retention_days
  copy_tags_to_snapshot               = true
  auto_minor_version_upgrade          = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]
  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = !var.deletion_protection
  final_snapshot_identifier           = var.deletion_protection ? "${local.name}-final" : null
  apply_immediately                   = true
}
