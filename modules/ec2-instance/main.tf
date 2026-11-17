data "aws_ami" "selected" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = "Security group for ${var.name}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Allow outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Ingress is only created when explicitly allowed, and never open to 0.0.0.0/0
# unless allow_public_ingress is true AND a CIDR is listed.
resource "aws_vpc_security_group_ingress_rule" "allowed" {
  for_each = var.allow_public_ingress ? toset(var.ingress_cidr_blocks) : toset([])

  security_group_id = aws_security_group.this.id
  description       = "Allowed ingress"
  ip_protocol       = "tcp"
  from_port         = var.ingress_port
  to_port           = var.ingress_port
  cidr_ipv4         = each.value
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.selected.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  associate_public_ip_address = var.associate_public_ip
  vpc_security_group_ids      = [aws_security_group.this.id]
  monitoring                  = true
  ebs_optimized               = true

  # IMDSv2 only.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = var.name })
}
