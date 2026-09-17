locals {
  prefix = var.project_prefix
}

# ------------------------------------------------------------------------------
# Data Sources for Pre-created AWS Infrastructure
# ------------------------------------------------------------------------------

data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = ["${local.prefix}-vpc"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "cidr-block"
    values = ["10.0.1.0/24", "10.0.3.0/24"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "cidr-block"
    values = ["10.0.2.0/24", "10.0.4.0/24"]
  }
}

data "aws_security_group" "ec2_sg" {
  name   = "${local.prefix}-ec2_sg"
  vpc_id = data.aws_vpc.selected.id
}

data "aws_security_group" "http_sg" {
  name   = "${local.prefix}-http_sg"
  vpc_id = data.aws_vpc.selected.id
}

data "aws_security_group" "sglb_sg" {
  name   = "${local.prefix}-sglb"
  vpc_id = data.aws_vpc.selected.id
}

data "aws_iam_instance_profile" "profile" {
  name = "${local.prefix}-instance_profile"
}

# Fetch dynamic Amazon Linux 2023 AMI ID in eu-west-1
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ------------------------------------------------------------------------------
# Launch Template & User Data Setup
# ------------------------------------------------------------------------------

resource "aws_launch_template" "template" {
  name          = "${local.prefix}-template"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type
  key_name      = "${local.prefix}-keypair"

  iam_instance_profile {
    arn = data.aws_iam_instance_profile.profile.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups = [
      data.aws_security_group.ec2_sg.id,
      data.aws_security_group.http_sg.id
    ]
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              dnf install -y httpd jq
              systemctl enable httpd
              systemctl start httpd

              TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
              PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

              cat <<HTML > /var/www/html/index.html
              <!DOCTYPE html>
              <html>
              <head>
                  <title>Application Instance</title>
              </head>
              <body>
                  <h1>Hello from EC2 Instance</h1>
                  <p><strong>Instance ID:</strong> $INSTANCE_ID</p>
                  <p><strong>Private IP:</strong> $PRIVATE_IP</p>
              </body>
              </html>
              HTML
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${local.prefix}-instance" })
  }

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Application Load Balancer, Target Group & Listener
# ------------------------------------------------------------------------------

resource "aws_lb" "loadbalancer" {
  name               = "${local.prefix}-loadbalancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [data.aws_security_group.sglb_sg.id]
  subnets            = data.aws_subnets.public.ids

  tags = var.tags
}

resource "aws_lb_target_group" "target_group" {
  name     = "cmtr-8k07hv2y-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.selected.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.loadbalancer.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn
  }

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Auto Scaling Group & ALB Target Group Attachment
# ------------------------------------------------------------------------------

resource "aws_autoscaling_group" "asg" {
  name                = "cmtr-8k07hv2y-asg"
  vpc_zone_identifier = data.aws_subnets.private.ids
  target_group_arns   = [aws_lb_target_group.target_group.arn]

  min_size                  = 2
  max_size                  = 2
  desired_capacity          = 2
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.template.id
    version = "$Latest"
  }

  lifecycle {
    ignore_changes = [
      desired_capacity,
      target_group_arns
    ]
  }
}

resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.asg.id
  lb_target_group_arn    = aws_lb_target_group.target_group.arn
}