# Vault HA Multi-Cloud: Production-Grade Secrets Infrastructure

**Secure, scalable, geographically distributed secrets management for AI infrastructure.**

## Overview

This repository contains a battle-tested, production-ready Vault HA cluster designed for multi-cloud deployments. It solves a critical problem at scale: **how do you run secrets management for thousands of distributed training and inference nodes without a single point of failure?**

**Key features:**
- ✅ 3-node HA Vault cluster (quorum-based, no split-brain)
- ✅ 3-node transit auto-unseal cluster (breaks the bootstrap problem)
- ✅ Multi-cloud deployment (AWS + OCI for cost arbitrage and disaster recovery)
- ✅ Automated failover and recovery
- ✅ Full Terraform IaC (deploy in 15 minutes)
- ✅ Sub-second secret rotation for distributed systems
- ✅ Scales to 1000+ nodes requesting secrets

## Why Multi-Cloud Vault?

### The Problem
- **Single-region Vault = single point of failure.** If your Vault cluster goes down, your entire platform can't rotate secrets, deploy new workloads, or authenticate to infrastructure services.
- **GPU cost variance.** If you're running training or inference clusters, GPU costs differ dramatically between AWS (p4d, h100) and OCI (BM.GPU.A100.40). A100s are 30-40% cheaper in OCI, but you need secrets management that works across both clouds.
- **Compliance + disaster recovery.** Financial services and ML platforms increasingly need cross-region failover. A single Vault cluster in us-east-1 doesn't cut it.

### Our Solution
We run **two independent Vault HA clusters**: one in AWS, one in OCI. They don't replicate to each other (that's complex), but they *both* integrate with a distributed model serving or training platform that:
- Writes to *both* clusters when creating new secrets
- Reads from the local cluster first (latency), falls back to remote (failover)
- Handles clock skew and network partitions gracefully

This is how you run **multi-cloud AI infrastructure reliably**.

## Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────┐
│                   AI Training / Inference Cluster            │
│  (1000+ nodes requesting secrets from Vault)                │
└────────┬──────────────────────────────────────────────────┬─┘
         │                                                  │
         ▼                                                  ▼
    ┌────────────────────────────┐  ┌──────────────────────────────┐
    │   AWS Region (us-west-2)   │  │   OCI Region (us-phoenix-1)  │
    │                            │  │                              │
    │  HA Vault Cluster          │  │  HA Vault Cluster            │
    │  ┌──────┬──────┬──────┐    │  │  ┌──────┬──────┬──────┐     │
    │  │ Node │ Node │ Node │    │  │  │ Node │ Node │ Node │     │
    │  │  1   │  2   │  3   │    │  │  │  1   │  2   │  3   │     │
    │  └──────┴──────┴──────┘    │  │  └──────┴──────┴──────┘     │
    │        (Raft Quorum)       │  │      (Raft Quorum)          │
    │                            │  │                              │
    │  ┌──────────────────────┐  │  │  ┌──────────────────────┐   │
    │  │ Transit Auto-Unseal  │  │  │  │ Transit Auto-Unseal  │   │
    │  │ (3 nodes)            │  │  │  │ (3 nodes)            │   │
    │  └──────────────────────┘  │  │  └──────────────────────┘   │
    └────────────────────────────┘  └──────────────────────────────┘
         Local: us-west-2                Remote: us-phoenix-1
       (Primary read/write)              (Failover/DR)
```

### Component Breakdown

#### 1. **Primary Vault HA Cluster (AWS)**
- 3 nodes (m5.large or better), spread across AZs
- Raft storage backend (no external DB dependency)
- TLS encryption in transit
- Integrated raft snapshot and recovery

#### 2. **Secondary Vault HA Cluster (OCI)**
- 3 nodes (VM.Standard.E4.Flex), spread across ADs
- Same Raft-based architecture
- Geographic failover: if AWS cluster is down, applications route to OCI

#### 3. **Transit Auto-Unseal (in each region)**
- 3-node cluster running Vault in "transit" mode
- Holds the master key (encrypted at rest in KMS)
- Automatically unseals the primary cluster at startup
- **Why?** Breaks the "unseal key" bootstrap problem—no manual operator intervention needed.

#### 4. **Network & Security**
- Internal VPC/subnet for Vault nodes (no internet exposure)
- TLS 1.3 for all Vault-to-Vault and client-to-Vault communication
- Vault namespace isolation for multi-tenancy
- AWS Secrets Manager + OCI Key Management integration

## Why This Works at 1000+ Nodes

1. **Horizontal scaling:** Vault itself doesn't scale horizontally (it's leader-based raft), but the *client side* can be load-balanced. Clients connect to all 3 nodes; requests are distributed. A single Vault cluster can handle 10,000+ req/s.

2. **Low latency:** Co-located clients can query Vault in the same region, achieving sub-50ms read latency even under load.

3. **Failover:** If one AZ fails, you still have a quorum (2/3 nodes alive). If the entire AWS region fails, clients failover to OCI—transparently.

4. **Cost:** Vault is lightweight (~1 CPU, ~2GB RAM per node). 3 nodes per region = ~$300/month per region (~$600/month total), negligible compared to GPU costs for training.

## Deployment

### Prerequisites
- Terraform >= 1.0
- AWS credentials configured
- OCI credentials configured
- `vault` CLI installed locally

### Quick Start (15 minutes)

```bash
# Clone this repo
git clone https://github.com/yourgithub/vault-ha-multi-cloud.git
cd vault-ha-multi-cloud

# Deploy AWS cluster
cd terraform/aws
terraform init
terraform apply -var-file="prod.tfvars"
# Wait ~5 minutes for instances to boot and unseal

# Deploy OCI cluster
cd ../oci
terraform init
terraform apply -var-file="prod.tfvars"
# Wait ~5 minutes

# Verify both clusters are healthy
vault status -address=https://vault-aws.internal:8200
vault status -address=https://vault-oci.internal:8200

# Initialize replication (one-time)
# See docs/REPLICATION.md
```

## Terraform Structure

```
terraform/
├── aws/
│   ├── main.tf              # VPC, security groups, instances
│   ├── vault.tf             # Vault server config, systemd unit
│   ├── transit-unseal.tf    # Transit cluster for auto-unseal
│   ├── kms.tf               # AWS KMS for key wrapping
│   └── prod.tfvars          # Production settings
├── oci/
│   ├── main.tf
│   ├── vault.tf
│   ├── transit-unseal.tf
│   ├── kms.tf               # OCI Key Management
│   └── prod.tfvars
└── modules/
    ├── vault_instance/      # Reusable instance setup
    └── vault_cluster/       # Reusable cluster config
```

Each region is independent but follows the same structure—easy to extend to additional clouds.

## Failure Modes & Recovery

See [ARCHITECTURE.md](./ARCHITECTURE.md) for detailed failure mode analysis:
- Raft snapshot corruption
- Unseal key loss
- Network partitions
- Node crashes
- Regional outages

Each scenario includes detection, recovery steps, and prevention.

## Runbooks

- **[Handle Raft Member Failure](./docs/runbook-raft-failure.md)** - Remove/replace a failed node
- **[Seal/Unseal Vault](./docs/runbook-seal-unseal.md)** - Manual intervention when needed
- **[Failover to Secondary Region](./docs/runbook-failover.md)** - Switch read/write to OCI
- **[Disaster Recovery](./docs/runbook-disaster-recovery.md)** - Full cluster recovery from backups

## Monitoring & Observability

This repo assumes you're exporting metrics to Datadog or Prometheus:

```hcl
# In vault.tf, we configure telemetry:
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname = true
}
```

Key metrics to watch:
- `vault.core.handle_request` (request latency)
- `vault.raft.apply` (raft replication latency)
- `vault.raft.peers` (cluster membership)
- `vault.logical.request` (operation counts by path)

See [docs/monitoring.md](./docs/monitoring.md) for full setup.

## Cost Breakdown (AWS + OCI)

| Component | Count | Instance Type | Region | Monthly Cost |
|-----------|-------|---|--------|--------|
| Vault HA Nodes | 3 | m5.large (AWS) | us-west-2 | $200 |
| Transit Auto-Unseal | 3 | t3.medium (AWS) | us-west-2 | $100 |
| Vault HA Nodes | 3 | E4.Flex (OCI) | us-phoenix-1 | $150 |
| Transit Auto-Unseal | 3 | E4.Flex (OCI) | us-phoenix-1 | $100 |
| **Total** | — | — | — | **~$550/month** |

*(Costs vary by region/instance selection; this is a baseline.)*

## Security Considerations

- **Encryption at rest:** All secrets encrypted with AES-256-GCM
- **Encryption in transit:** TLS 1.3 for all communication
- **RBAC:** Vault namespaces for multi-tenant isolation
- **Audit logging:** All auth attempts, secret reads, and policy changes logged to persistent storage
- **Key rotation:** Vault supports automatic key rotation policies

See [docs/security.md](./docs/security.md) for detailed compliance checklist.

## Integration Examples

### Kubernetes Pod Authentication

```hcl
# Enable Kubernetes auth method
vault auth enable kubernetes

# Create a policy for ML training pods
path "secret/data/training/*" {
  capabilities = ["read", "list"]
}

# Pods request a token via service account, get secrets automatically
```

### Dynamic Database Credentials

```hcl
# Enable dynamic secrets for PostgreSQL
vault secrets enable database

# A training job requests DB credentials
# Vault creates a temporary user + password
# Credentials expire after job completes
```

### Model Serving Secret Rotation

```bash
# vLLM model serving container requests auth token
curl -s -H "Authorization: Bearer $(cat /var/run/secrets/vault/token)" \
     https://vault.internal/v1/auth/token/renew-self

# Token refreshes automatically; secrets rotate every 24h
```

## Maintenance

### Weekly
- Check cluster health: `vault operator raft autopilot state`
- Monitor raft logs for errors
- Verify backups are running

### Monthly
- Test disaster recovery procedure (restore from snapshot)
- Review audit logs
- Update Vault version (if patch release available)

### Quarterly
- Full chaos engineering: simulate node failures, region outages
- Audit access policies
- Capacity planning (are we approaching any limits?)

## FAQ

**Q: Why not use Vault Cloud / HashiCorp Cloud Platform?**  
A: We need geographic control, cost predictability, and integration with internal systems. Self-hosted gives us that.

**Q: What about Kubernetes-native secrets (etcd encryption)?**  
A: etcd scales to ~100 nodes before becoming a bottleneck. At 1000+ nodes, Vault's distributed design is necessary.

**Q: How do we handle secrets for multi-tenant clusters?**  
A: Vault namespaces + RBAC policies ensure team A can't read team B's secrets. See [docs/multi-tenancy.md](./docs/multi-tenancy.md).

**Q: What's the RTO/RPO?**  
A: RTO (Recovery Time Objective) = ~2-5 minutes (detect failure, failover, clients reconnect).  
RPO (Recovery Point Objective) = ~1 minute (raft snapshots every minute).

## Next Steps

1. **Deploy to staging:** Use the Terraform modules to spin up a test cluster in a non-production environment
2. **Integration testing:** Verify your workloads can authenticate and retrieve secrets
3. **Observability:** Set up Datadog dashboards for Vault metrics
4. **Runbook testing:** Simulate failures and verify runbook procedures work
5. **Production cutover:** Migrate existing secret management to this cluster

## Contributing

This is a production template. Contributions should:
- Include test coverage for Terraform changes
- Add runbook entries for any new failure modes
- Update monitoring alerts if new components added

## License

MIT

---

**Questions?** Open an issue or see [docs/](./docs) for detailed guides.

**Ready to deploy?** Start with `terraform/aws` → `terraform/oci`. Takes 15 minutes.
