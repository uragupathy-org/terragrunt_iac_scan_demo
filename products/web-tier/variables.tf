variable "name" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "root_volume_size_gb" {
  type = number
}

variable "ami_name_filter" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "associate_public_ip" {
  type    = bool
  default = false
}

variable "allow_public_ingress" {
  type    = bool
  default = false
}

variable "ingress_cidr_blocks" {
  type    = list(string)
  default = []
}

variable "ingress_port" {
  type    = number
  default = 443
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}
