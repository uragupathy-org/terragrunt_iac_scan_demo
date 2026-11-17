# Unit: client environment "dev" in ap-southeast-2, EC2 web instance.
# Layers: client repo (this file) -> product (products/web-tier, flat: resources declared directly).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  # Static product defaults (identical across client environments).
  defaults = read_terragrunt_config("${get_repo_root()}/products/web-tier/defaults.hcl").locals
}

terraform {
  # Copy the whole repo so the product path resolves.
  source = "${get_repo_root()}//products/web-tier"
}

# Environment-specific values from the client repo.
inputs = {
  name = "client-demo-dev-web"
  # Default VPC of the umatrenddemo account (ap-southeast-2a subnet).
  subnet_id            = "subnet-04730e7b4814e3a80"
  vpc_id               = "vpc-03984c3d845fe2475"
  instance_type        = local.defaults.instance_type
  root_volume_size_gb  = local.defaults.root_volume_size_gb
  ami_name_filter      = local.defaults.ami_name_filter
  associate_public_ip  = local.defaults.associate_public_ip
  allow_public_ingress = local.defaults.allow_public_ingress
  ingress_cidr_blocks  = local.defaults.ingress_cidr_blocks
  ingress_port         = local.defaults.ingress_port
  tags                 = local.defaults.tags
  extra_tags = {
    Environment = "dev"
  }
}
