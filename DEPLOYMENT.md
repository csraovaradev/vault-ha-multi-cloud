# Deployment Guide: Vault HA Multi-Cloud

This guide walks through deploying Vault HA clusters to AWS and OCI.

## Prerequisites

### Required Tools
- Terraform >= 1.0
- AWS CLI v2 (configured with credentials)
- OCI CLI (configured with credentials)
- `vault` CLI >= 1.15.0
- SSH key pair (for instance access)

### AWS Setup
```bash
# Configure AWS credentials
aws configure
# or use environment variables:
export AWS_ACCESS_KEY_ID=<your-key>
export AWS_SECRET_ACCESS_KEY=<your-secret>
```

### OCI Setup
```bash
# Configure OCI credentials
mkdir -p ~/.oci
# Copy your OCI API key files to ~/.oci/
# Update your compartment OCID below
```

## Deployment Steps

### Phase 1: Deploy AWS Cluster (20-25 minutes)

```bash
cd terraform/aws

# Initialize Terraform
terraform init

# Review what will be created
terraform plan -var-file="prod.tfvars"

# Deploy the cluster
terraform apply -var-file="prod.tfvars"

# Save outputs for later reference
terraform output > /tmp/aws-outputs.txt
```

**What gets created:**
- VPC with public/private subnets (3 AZs)
- NAT gateways for outbound traffic
- 3 Vault HA nodes in private subnets
- 3 Transit auto-unseal nodes in private subnets
- KMS key for automatic unsealing
- Security groups with restrictive inbound rules

**Wait 5-7 minutes for:**
1. Instances to boot
2. Vault to install via user-data
3. Vault to unseal automatically via KMS
4. Cluster to form via Raft

### Phase 2: Verify AWS Cluster

```bash
# Get the Vault addresses from Terraform
export VAULT_ADDR_AWS=$(terraform output -raw vault_addresses | head -1 | tr -d '"')

# Check cluster health
vault status -address=https://${VAULT_ADDR_AWS} \
  -ca-cert=/path/to/ca.crt  # You'll need the CA cert from the cluster

# List Raft members
vault operator raft list-peers -address=https://${VAULT_ADDR_AWS} \
  -ca-cert=/path/to/ca.crt

# Expected: 3 nodes all "alive", 1 leader
```

**Note:** The instances use self-signed certificates. To verify cluster health from outside the VPC, you'll need to:
1. SSH into one of the instances
2. Run `vault operator raft list-peers` locally
3. Or use AWS Systems Manager Session Manager to connect without SSH

### Phase 3: Deploy OCI Cluster (20-25 minutes)

```bash
cd terraform/oci

terraform init

# Create terraform.tfvars with your OCI compartment OCID
cat > terraform.tfvars << 'EOF'
compartment_ocid = "ocid1.compartment.oc1...."  # Replace with your compartment OCID
ssh_public_key   = "ssh-rsa AAAA..."             # Your SSH public key
oci_region       = "us-phoenix-1"
EOF

terraform plan

terraform apply
```

**What gets created:**
- VCN with public/private subnets (3 ADs)
- NAT gateways
- 3 Vault HA nodes
- OCI KMS key for auto-unseal
- Network security groups

### Phase 4: Verify OCI Cluster

```bash
# Similar to AWS verification
export VAULT_ADDR_OCI=$(terraform output -raw vault_addresses | head -1 | tr -d '"')

# SSH into an OCI instance
ssh ubuntu@<public-ip>

# From within the instance
vault operator raft list-peers

# Should show: 3 OCI nodes, all alive, 1 leader
```

## Post-Deployment Configuration

### Initialize Vault Secrets Engine

From inside a Vault instance:

```bash
# Enable KV secrets engine
vault secrets enable -path=secret -version=2 kv

# Create a test secret
vault kv put secret/test password="hello-world" username="admin"

# Verify
vault kv get secret/test
```

### Set Up Replication (Optional)

If you want the AWS and OCI clusters to be aware of each other (for failover):

```bash
# This is optional and complex; see docs/REPLICATION.md for details
```

## Monitoring & Health Checks

### Datadog Integration

If you use Datadog:

1. **Install Datadog agent** on Vault instances via user-data (not included in bootstrap script)
2. **Configure Prometheus scrape** to collect Vault metrics
3. **Import Vault dashboard** from Datadog community

Key metrics:
- `vault.core.handle_request` (request latency)
- `vault.raft.apply` (replication latency)
- `vault.raft.peers` (cluster membership)

### CloudWatch / OCI Monitoring

AWS instances automatically send logs to CloudWatch. Check:
- `/var/log/vault/vault.log` (on instances)
- CloudWatch Logs for Vault service logs

## Scaling Considerations

### Can Handle
- 1000+ concurrent clients (use connection pooling)
- 100K+ secrets (Raft can handle massive datasets)
- 1000+ req/s (depends on operation type)

### Performance Notes
- **Read latency:** ~50-100ms (local region)
- **Write latency:** ~100-200ms (raft replication)
- **Failover latency:** ~1-2 seconds (new leader election)

### Capacity Tuning
If you need to handle more load:
1. Increase instance size (m5.2xlarge for AWS, or increase OCPU for OCI)
2. Add more Vault servers (requires Raft cluster scaling)
3. Use client-side caching for frequently-accessed secrets

## Troubleshooting

### Vault Won't Unseal
```bash
# SSH into the instance
ssh ubuntu@<instance-ip>

# Check if KMS is accessible
aws kms describe-key --key-id <KMS_KEY_ID> --region us-west-2

# Check Vault logs
sudo tail -50 /var/log/vault/vault.log

# Try manual unseal (if you have shamir keys)
vault operator unseal <key>
```

### Cluster Members Won't Join
```bash
# Verify network connectivity between subnets
ping vault-aws-2.internal  # from vault-aws-1

# Check raft state
vault operator raft autopilot state

# Force rejoin if needed
vault operator raft remove-peer <node-id>
vault operator raft join https://<leader-ip>:8200
```

### High Replication Latency
- Check network between instances: `mtr -r vault-aws-2.internal`
- Check disk I/O: `iostat -x 1`
- Consider increasing instance size

## Backup & Restore

### Daily Backup
```bash
# Run this via cron on one of the Vault instances
vault operator raft snapshot save /mnt/vault/backup-$(date +%s).snap

# Upload to S3
aws s3 cp /mnt/vault/backup-*.snap s3://vault-backups/
```

### Restore from Backup
```bash
# Fetch snapshot from S3
aws s3 cp s3://vault-backups/backup-<timestamp>.snap /tmp/

# Stop Vault
systemctl stop vault

# Restore
vault operator raft snapshot restore /tmp/backup-*.snap

# Start Vault
systemctl start vault
```

## Cost Estimation

### AWS
- 3 × m5.large: ~$100/month
- 3 × t3.medium (transit): ~$30/month
- Data transfer: ~$10/month
- **Total: ~$140/month**

### OCI
- 3 × E4.Flex (2 OCPU, 8GB): ~$100/month
- KMS: ~$5/month
- **Total: ~$105/month**

### Combined
**~$245/month** for a production-grade HA Vault cluster across two clouds.

## Next Steps

1. **Add monitoring:** Integrate with Datadog/Prometheus
2. **Automate backups:** Set up daily snapshots to S3 + OCI Object Storage
3. **Test failover:** Manually verify failover from AWS → OCI
4. **Document policies:** Create backup/disaster recovery runbooks
5. **Integrate with applications:** Configure client auth (K8s, database, etc.)

## Support & Escalation

For issues beyond this guide:
- Review [ARCHITECTURE.md](./ARCHITECTURE.md) for failure mode details
- Check [docs/runbook-*.md](./docs/) for operational procedures
- Consult [Vault documentation](https://www.vaultproject.io/docs)

---

**Ready to deploy?** Start with `terraform/aws`. The entire setup takes ~1 hour end-to-end.
