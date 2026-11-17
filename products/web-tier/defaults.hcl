# Product defaults: static across every client environment.
# Units read this file and may override individual values in their own inputs.

locals {
  instance_type        = "t3.micro"
  root_volume_size_gb  = 20
  ami_name_filter      = "al2023-ami-2023.*-x86_64"
  allow_public_ingress = false
  ingress_cidr_blocks  = []
  ingress_port         = 443
  associate_public_ip  = false
  tags = {
    Product = "web-tier"
  }
}
