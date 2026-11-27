resource "aws_launch_template" "pac" {
  name_prefix   = "${local.name}-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  ebs_optimized = true
  user_data     = base64encode(local.user_data)

  iam_instance_profile {
    name = local.instance_profile_name
  }

  monitoring {
    enabled = true
  }
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app.id]
    delete_on_termination       = true
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.main.arn
      delete_on_termination = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name}-node"
      Role = "pac-backend"
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [image_id]
  }
}

# Paso 4: el "encargado". Mantiene entre 2 y 4 nodos repartidos en las 2 zonas
# y los registra solos en los dos grupos de destino del ALB.
resource "aws_autoscaling_group" "pac" {
  name             = "${local.name}-asg"
  min_size         = 2
  max_size         = 4
  desired_capacity = 2

  vpc_zone_identifier = aws_subnet.app[*].id
  target_group_arns   = [aws_lb_target_group.pac.arn, aws_lb_target_group.front.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 300
  default_instance_warmup   = 180

  launch_template {
    id      = aws_launch_template.pac.id
    version = aws_launch_template.pac.latest_version
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-node"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "pac-backend"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }

  depends_on = [aws_nat_gateway.nat, aws_route_table_association.app, aws_kms_key.main]
}

# Paso 5: la regla de escalado. Mantiene el CPU promedio del grupo cerca de 50 %.
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.name}-cpu-objetivo"
  autoscaling_group_name = aws_autoscaling_group.pac.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}