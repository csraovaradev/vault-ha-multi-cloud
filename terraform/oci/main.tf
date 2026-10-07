terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }

  # backend "s3" {
  #   bucket         = "vault-terraform-state"
  #   key            = "vault-oci/terraform.tfstate"
  #   region         = "us-west-2"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}

provider "oci" {
  region = var.oci_region
}

# Compartment (typically already exists; update to your compartment OCID)
data "oci_identity_compartments" "main" {
  compartment_id          = var.compartment_ocid
  access_level            = "ANY"
  compartment_id_in_subtree = false

  filter {
    name   = "state"
    values = ["ACTIVE"]
  }
}

# Virtual Cloud Network (VCN)
resource "oci_core_vcn" "vault" {
  compartment_id = var.compartment_ocid
  cidr_block     = var.vcn_cidr
  display_name   = "vault-vcn"
  dns_label      = "vaultnet"

  defined_tags = {
    "Project" = {
      "Environment" = var.environment
    }
  }
}

# Public subnet for NAT gateways
resource "oci_core_subnet" "public" {
  count                      = 3
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.vault.id
  cidr_block                 = cidrsubnet(var.vcn_cidr, 2, count.index)
  display_name               = "vault-public-${count.index + 1}"
  dns_label                  = "public${count.index + 1}"
  map_public_ip_on_launch    = false
  prohibit_public_ip_on_instance = false

  route_table_id = oci_core_route_table.public[count.index].id
  security_list_ids = [
    oci_core_security_list.public[count.index].id
  ]
}

# Private subnet for Vault nodes
resource "oci_core_subnet" "private" {
  count                       = 3
  compartment_id              = var.compartment_ocid
  vcn_id                      = oci_core_vcn.vault.id
  cidr_block                  = cidrsubnet(var.vcn_cidr, 2, count.index + 3)
  display_name                = "vault-private-${count.index + 1}"
  dns_label                   = "private${count.index + 1}"
  prohibit_public_ip_on_instance = true

  route_table_id = oci_core_route_table.private[count.index].id
  security_list_ids = [
    oci_core_security_list.private[count.index].id
  ]
}

# Internet Gateway
resource "oci_core_internet_gateway" "vault" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vault.id
  display_name   = "vault-igw"
  enabled        = true
}

# NAT Gateway
resource "oci_core_nat_gateway" "vault" {
  count          = 3
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vault.id
  display_name   = "vault-nat-${count.index + 1}"
}

# Route table for public subnets
resource "oci_core_route_table" "public" {
  count          = 3
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vault.id
  display_name   = "public-rt-${count.index + 1}"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.vault.id
  }
}

# Route table for private subnets
resource "oci_core_route_table" "private" {
  count          = 3
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vault.id
  display_name   = "private-rt-${count.index + 1}"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_nat_gateway.vault[count.index].id
  }
}

# Security list for public subnets
resource "oci_core_security_list" "public" {
  count          = 3
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vault.id
  display_name   = "public-sl-${count.index + 1}"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 443
      max = 443
    }
  }
}

# Security list for private subnets (Vault cluster)
resource "oci_core_security_list" "private" {
  count          = 3
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vault.id
  display_name   = "private-sl-${count.index + 1}"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  # Raft communication (internal)
  ingress_security_rules {
    protocol = "6"
    source   = var.vcn_cidr

    tcp_options {
      min = 8201
      max = 8201
    }
    description = "Raft peer communication"
  }

  # Vault API (internal)
  ingress_security_rules {
    protocol = "6"
    source   = var.vcn_cidr

    tcp_options {
      min = 8200
      max = 8200
    }
    description = "Vault API"
  }

  # SSH (from bastion only in production)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 22
      max = 22
    }
    description = "SSH (restrict in production)"
  }
}

# Data source: Available ADs
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

# Data source: Latest Ubuntu image
data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.instance_shape

  filter {
    name   = "display_name"
    values = ["Canonical-Ubuntu-22.04-*"]
  }

  sort_by = "TIMECREATED"
  sort_order = "DESC"
}

# OCI KMS Key for auto-unseal
resource "oci_kms_key" "vault" {
  compartment_id = var.compartment_ocid
  display_name   = "vault-unseal-key"

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  protection_mode = "HSM" # Use HSM-backed KMS
}

# Create KMS vault (contains the key)
resource "oci_kms_vault" "vault" {
  compartment_id = var.compartment_ocid
  display_name   = "vault-kms"
  vault_type     = "DEFAULT"
}

# Compute instances for Vault
resource "oci_core_instance" "vault" {
  count               = 3
  compartment_id      = var.compartment_ocid
  display_name        = "vault-oci-${count.index + 1}"
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[count.index % length(data.oci_identity_availability_domains.ads.availability_domains)].name
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  create_vnic_details {
    subnet_id              = oci_core_subnet.private[count.index].id
    private_ip             = cidrhost(oci_core_subnet.private[count.index].cidr_block, 10 + count.index)
    skip_source_dest_check = false
    nsg_ids                = [oci_core_network_security_group.vault.id]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(templatefile("${path.module}/user-data.sh", {
      vault_version    = var.vault_version
      kms_key_id       = oci_kms_key.vault.id
      oci_region       = var.oci_region
      vault_node_index = count.index
      vault_node_name  = "vault-oci-${count.index + 1}"
    }))
  }

  source_details {
    source_id   = data.oci_core_images.ubuntu.images[0].id
    source_type = "IMAGE"
  }

  boot_volume_details {
    display_name = "vault-oci-${count.index + 1}-boot"

    backup_policy {
      backup_type = "INCREMENTAL"
    }
  }

  depends_on = [
    oci_core_nat_gateway.vault
  ]
}

# Network Security Group for Vault
resource "oci_core_network_security_group" "vault" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vault.id
  display_name   = "vault-nsg"
}

# Outputs
output "vault_addresses" {
  value = [for i, instance in oci_core_instance.vault : "https://${instance.create_vnic_details[0].private_ip}:8200"]
}

output "vault_node_names" {
  value = [for i in range(3) : "vault-oci-${i + 1}"]
}

output "vcn_id" {
  value = oci_core_vcn.vault.id
}
