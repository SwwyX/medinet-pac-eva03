output "url" {
  value = "https://${var.domain_name}"
}

output "swagger" {
  value = "https://${var.domain_name}/docs"
}

output "name_servers" {
  description = "Copiar estos NS en el proveedor del dominio gratuito (delegación)"
  value       = var.create_hosted_zone ? aws_route53_zone.main[0].name_servers : []
}

output "alb_dns_name" {
  value = aws_lb.pac.dns_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.pac.repository_url
}

output "autoscaling_group_name" {
  value = aws_autoscaling_group.pac.name
}

output "image_tag_parameter" {
  value = aws_ssm_parameter.image_tag.name
}

output "jwt_secret_parameter" {
  value = aws_ssm_parameter.jwt_secret.name
}

output "github_deploy_role_arn" {
  value = length(aws_iam_role.github_deploy) > 0 ? aws_iam_role.github_deploy[0].arn : ""
}

output "rds_endpoint" {
  value = aws_db_instance.pac.address
}
