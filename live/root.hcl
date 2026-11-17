# Root configuration inherited by every unit in the client repo.
# Holds only settings that are common to all environments of this client.

locals {
  # Client-wide values, injected at the Terragrunt layer.
  client_name = "client-demo"
  aws_region  = "ap-southeast-2"
}

# Local state keeps the demo self-contained (no S3 bucket needed).
# Replace with an S3 backend + DynamoDB lock table for a real client.
generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  backend "local" {
    path = "${get_terragrunt_dir()}/terraform.tfstate"
  }
}
EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"
  default_tags {
    tags = {
      Client    = "${local.client_name}"
      ManagedBy = "terragrunt"
    }
  }
}
EOF
}
