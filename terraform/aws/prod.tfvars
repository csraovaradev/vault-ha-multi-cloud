# Production configuration for AWS Vault HA cluster

aws_region            = "us-west-2"
environment           = "production"
vpc_cidr              = "10.0.0.0/16"
instance_type         = "m5.large"     # For production, consider m5.xlarge
transit_instance_type = "t3.medium"
vault_version         = "1.15.0"

# Adjust these for your needs:
# instance_type options:
#   - m5.large (4 CPU, 16GB) - suitable for small/medium deployments
#   - m5.xlarge (4 CPU, 16GB) - suitable for medium deployments
#   - m5.2xlarge (8 CPU, 32GB) - suitable for large deployments
#
# transit_instance_type options:
#   - t3.medium - fine for most deployments
#   - t3.large - if you have very high unsealing frequency
