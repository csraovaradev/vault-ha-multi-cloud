terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment for production (store state in S3)
  # backend "s3" {
  #   bucket         = "vault-terraform-state"
  #   key            = "vault-aws/terraform.tfstate"
  #   region         = "us-west-2"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = "Vault-HA-MultiCloud"
    }
  }
}

# VPC
resource "aws_vpc" "vault" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "vault-vpc"
  }
}

# Internet Gateway (for bastion/monitoring access)
resource "aws_internet_gateway" "vault" {
  vpc_id = aws_vpc.vault.id

  tags = {
    Name = "vault-igw"
  }
}

# Public Subnets (for NAT gateway)
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.vault.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "vault-public-${count.index + 1}"
  }
}

# Private Subnets (for Vault nodes)
resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.vault.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, count.index + 3)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "vault-private-${count.index + 1}"
  }
}

# Elastic IPs for NAT
resource "aws_eip" "nat" {
  count  = 3
  domain = "vpc"

  tags = {
    Name = "vault-nat-eip-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.vault]
}

# NAT Gateways
resource "aws_nat_gateway" "vault" {
  count         = 3
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "vault-nat-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.vault]
}

# Route tables for public subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vault.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vault.id
  }

  tags = {
    Name = "vault-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Route tables for private subnets
resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.vault.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.vault[count.index].id
  }

  tags = {
    Name = "vault-private-rt-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Security Group for Vault
resource "aws_security_group" "vault" {
  name        = "vault-sg"
  description = "Security group for Vault HA cluster"
  vpc_id      = aws_vpc.vault.id

  # Raft communication (internal)
  ingress {
    from_port       = 8201
    to_port         = 8201
    protocol        = "tcp"
    security_groups = [aws_security_group.vault.id]
    description     = "Raft peer communication"
  }

  # API access (internal only)
  ingress {
    from_port       = 8200
    to_port         = 8200
    protocol        = "tcp"
    cidr_blocks     = [var.vpc_cidr]
    description     = "Vault API (internal VPC only)"
  }

  # SSH (from bastion only - update to your bastion SG in production)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # CHANGE THIS in production
    description = "SSH access (restrict in production)"
  }

  # Egress (all traffic allowed)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vault-sg"
  }
}

# Data source: Availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source: Latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# IAM Role for Vault instances
resource "aws_iam_role" "vault" {
  name = "vault-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for KMS (auto-unseal)
resource "aws_iam_role_policy" "vault_kms" {
  name = "vault-kms-policy"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey",
        ]
        Resource = [aws_kms_key.vault.arn]
      }
    ]
  })
}

# IAM Policy for CloudWatch Logs
resource "aws_iam_role_policy" "vault_logs" {
  name = "vault-logs-policy"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# Instance profile
resource "aws_iam_instance_profile" "vault" {
  name = "vault-instance-profile"
  role = aws_iam_role.vault.name
}

# KMS Key for auto-unseal
resource "aws_kms_key" "vault" {
  description             = "KMS key for Vault auto-unseal"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name = "vault-unseal-key"
  }
}

resource "aws_kms_alias" "vault" {
  name          = "alias/vault-unseal"
  target_key_id = aws_kms_key.vault.key_id
}

# EC2 instances for Vault
resource "aws_instance" "vault" {
  count                = 3
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.vault.name
  subnet_id            = aws_subnet.private[count.index].id

  vpc_security_group_ids = [aws_security_group.vault.id]

  # EBS volume for Raft storage
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    delete_on_termination = true
    encrypted             = true
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    vault_version    = var.vault_version
    kms_key_id       = aws_kms_key.vault.id
    aws_region       = var.aws_region
    vault_node_index = count.index
    vault_node_name  = "vault-aws-${count.index + 1}"
  }))

  tags = {
    Name = "vault-aws-${count.index + 1}"
  }
}

# Elastic IPs for Vault nodes (for consistent DNS)
resource "aws_eip" "vault" {
  count    = 3
  instance = aws_instance.vault[count.index].id
  domain   = "vpc"

  tags = {
    Name = "vault-aws-${count.index + 1}-eip"
  }

  depends_on = [aws_internet_gateway.vault]
}

# Security group for Transit Auto-Unseal cluster
resource "aws_security_group" "transit" {
  name        = "vault-transit-sg"
  description = "Security group for Vault Transit auto-unseal cluster"
  vpc_id      = aws_vpc.vault.id

  # Raft communication
  ingress {
    from_port       = 8201
    to_port         = 8201
    protocol        = "tcp"
    security_groups = [aws_security_group.transit.id]
    description     = "Transit raft peer communication"
  }

  # API access (from Vault cluster)
  ingress {
    from_port       = 8200
    to_port         = 8200
    protocol        = "tcp"
    security_groups = [aws_security_group.vault.id]
    description     = "Vault cluster access to transit"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vault-transit-sg"
  }
}

# Transit instances
resource "aws_instance" "transit" {
  count                = 3
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.transit_instance_type
  iam_instance_profile = aws_iam_instance_profile.vault.name
  subnet_id            = aws_subnet.private[count.index].id

  vpc_security_group_ids = [aws_security_group.transit.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
  }

  user_data = base64encode(templatefile("${path.module}/user-data-transit.sh", {
    vault_version   = var.vault_version
    kms_key_id      = aws_kms_key.vault.id
    aws_region      = var.aws_region
    transit_node_id = count.index
  }))

  tags = {
    Name = "vault-transit-${count.index + 1}"
  }
}

# Data source: Current AWS account
data "aws_caller_identity" "current" {}

# Outputs
output "vault_addresses" {
  value = [for i, instance in aws_instance.vault : "https://${instance.private_ip}:8200"]
}

output "vault_node_names" {
  value = [for i in range(3) : "vault-aws-${i + 1}"]
}

output "kms_key_id" {
  value = aws_kms_key.vault.id
}

output "vpc_id" {
  value = aws_vpc.vault.id
}
