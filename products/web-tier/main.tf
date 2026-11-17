# Product: a composition of modules. Client units select a source of this
# directory and inject environment-specific values as variables.

module "web_instance" {
  source = "../../modules/ec2-instance"

  name                 = var.name
  instance_type        = var.instance_type
  root_volume_size_gb  = var.root_volume_size_gb
  ami_name_filter      = var.ami_name_filter
  subnet_id            = var.subnet_id
  vpc_id               = var.vpc_id
  associate_public_ip  = var.associate_public_ip
  allow_public_ingress = var.allow_public_ingress
  ingress_cidr_blocks  = var.ingress_cidr_blocks
  ingress_port         = var.ingress_port
  tags                 = merge(var.tags, var.extra_tags)
}
