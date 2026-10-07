variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  description = "EC2 instance type for Vault nodes"
  type        = string
  default     = "m5.large"
}

variable "transit_instance_type" {
  description = "EC2 instance type for Transit auto-unseal nodes"
  type        = string
  default     = "t3.medium"
}

variable "vault_version" {
  description = "Vault version to install"
  type        = string
  default     = "1.15.0"
}
