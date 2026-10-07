variable "compartment_ocid" {
  description = "OCID of the compartment"
  type        = string
}

variable "oci_region" {
  description = "OCI region for deployment"
  type        = string
  default     = "us-phoenix-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "vcn_cidr" {
  description = "CIDR block for VCN"
  type        = string
  default     = "10.1.0.0/16"
}

variable "instance_shape" {
  description = "Compute instance shape"
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "instance_ocpus" {
  description = "Number of OCPUs for compute instances"
  type        = number
  default     = 2
}

variable "instance_memory_gb" {
  description = "Memory in GB for compute instances"
  type        = number
  default     = 8
}

variable "vault_version" {
  description = "Vault version to install"
  type        = string
  default     = "1.15.0"
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
}
