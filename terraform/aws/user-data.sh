#!/bin/bash
set -e

# Vault HA Multi-Cloud: AWS Bootstrap Script
# This script installs and configures Vault for a 3-node HA cluster

VAULT_VERSION="${vault_version}"
KMS_KEY_ID="${kms_key_id}"
AWS_REGION="${aws_region}"
VAULT_NODE_INDEX="${vault_node_index}"
VAULT_NODE_NAME="${vault_node_name}"

# Logging
exec > >(tee /var/log/vault-bootstrap.log)
exec 2>&1

echo "=== Vault Bootstrap Started at $(date) ==="

# Update system
apt-get update
apt-get install -y curl unzip jq aws-cli

# Create vault user
useradd --system --home /etc/vault --shell /bin/false vault || true

# Create directories
mkdir -p /opt/vault /mnt/vault/raft /mnt/vault/logs
chown -R vault:vault /opt/vault /mnt/vault

# Download and install Vault
cd /opt/vault
curl -sL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip" -o vault.zip
unzip -q vault.zip
rm -f vault.zip
chmod +x vault

# Create Vault configuration
cat > /etc/vault/vault.hcl << 'EOF'
disable_cache = false
disable_mlock = true  # Set to false in production for large memory deployments

storage "raft" {
  path = "/mnt/vault/raft"
  node_id = "VAULT_NODE_NAME"
  performance_multiplier = 8
  # Initial peers (these should be updated after all nodes are up)
  retry_join {
    leader_api_addr = "https://vault-aws-1.internal:8200"
  }
  retry_join {
    leader_api_addr = "https://vault-aws-2.internal:8200"
  }
  retry_join {
    leader_api_addr = "https://vault-aws-3.internal:8200"
  }
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault/certs/vault.crt"
  tls_key_file  = "/etc/vault/certs/vault.key"
  telemetry {
    unauthenticated_metrics_access = true
  }
}

seal "awskms" {
  region  = "AWS_REGION"
  kms_key_id = "KMS_KEY_ID"
}

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname = true
}

api_addr      = "https://127.0.0.1:8200"
cluster_addr  = "https://127.0.0.1:8201"
ui            = true
log_level     = "Info"
EOF

# Replace placeholders
sed -i "s/VAULT_NODE_NAME/${VAULT_NODE_NAME}/g" /etc/vault/vault.hcl
sed -i "s/AWS_REGION/${AWS_REGION}/g" /etc/vault/vault.hcl
sed -i "s/KMS_KEY_ID/${KMS_KEY_ID}/g" /etc/vault/vault.hcl

# Generate self-signed certificates (for production, use proper PKI)
mkdir -p /etc/vault/certs
cd /etc/vault/certs

openssl req -new -x509 -days 365 -nodes \
  -out vault.crt -keyout vault.key \
  -subj "/CN=${VAULT_NODE_NAME}.internal"

chmod 600 vault.key
chown vault:vault vault.crt vault.key

# Create systemd service
cat > /etc/systemd/system/vault.service << 'EOF'
[Unit]
Description=HashiCorp Vault
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault/vault.hcl
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=notify
ExecStart=/opt/vault/vault server -config=/etc/vault/vault.hcl
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitNPROC=512
User=vault
Group=vault
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vault

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Vault
systemctl daemon-reload
systemctl enable vault
systemctl start vault

# Wait for Vault to start and unseal automatically
echo "Waiting for Vault to unseal via KMS..."
for i in {1..30}; do
  if /opt/vault/vault status -address=https://127.0.0.1:8200 2>/dev/null | grep -q "Sealed.*false"; then
    echo "✓ Vault unsealed successfully"
    break
  fi
  echo "Attempt $i: Waiting for unseal..."
  sleep 2
done

# Health check
/opt/vault/vault status -address=https://127.0.0.1:8200 || echo "WARNING: Vault status check failed"

echo "=== Vault Bootstrap Completed at $(date) ==="
