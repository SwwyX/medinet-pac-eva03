# Nodos backend (mínimo 2, repartidos en las 2 zonas de disponibilidad), sin IP pública.
# Se administran por SSM Session Manager: no hay puerto 22 ni llave .pem.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region         = data.aws_region.current.region
    project        = var.project
    ecr_registry   = split("/", aws_ecr_repository.pac.repository_url)[0]
    ecr_repository = aws_ecr_repository.pac.repository_url
    db_host        = aws_db_instance.pac.address
    db_name        = aws_db_instance.pac.db_name
    db_secret_arn  = aws_db_instance.pac.master_user_secret[0].secret_arn
    log_group      = aws_cloudwatch_log_group.app.name
    cors_origins   = var.cors_origins
    target_group   = aws_lb_target_group.pac.arn
    target_front   = aws_lb_target_group.front.arn
  })
}

# Los nodos (EC2) ya no se declaran uno a uno: los crea el Auto Scaling Group de autoscaling.tf
# a partir del Launch Template, y el grupo los registra solo en los grupos de destino del ALB.
