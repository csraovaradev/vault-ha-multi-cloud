#!/bin/bash
set -e

# Vault Transit Auto-Unseal: AWS Bootstrap Script
# This script installs Vault in transit mode for auto-unsealing the main cluster

VAULT_VERSION="${vault_version}"
KMS_KEY_ID="${kms_key_id}"
AWS_REGION="${aws_region}"
TRANSIT_NODE_ID="${transit_node_id}"

exec > >(tee /var/log/vault-transit-bootstrap.log)
exec 2>&1

echo "=== Vault Transit Bootstrap Started at $(date) ==="

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

# Create Vault configuration for Transit mode
cat > /etc/vault/vault.hcl << 'EOF'
disable_cache = false
disable_mlock = true

storage "raft" {
  path = "/mnt/vault/raft"
  node_id = "TRANSIT_NODE_ID"
  performance_multiplier = 8
  retry_join {
    leader_api_addr = "https://vault-transit-1.internal:8200"
  }
  retry_join {
    leader_api_addr = "https://vault-transit-2.internal:8200"
  }
  retry_join {
    leader_api_addr = "https://vault-transit-3.internal:8200"
  }
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault/certs/vault.crt"
  tls_key_file  = "/etc/vault/certs/vault.key"
}

seal "awskms" {
  region     = "AWS_REGION"
  kms_key_id = "KMS_KEY_ID"
}

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname = true
}

api_addr     = "https://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"
ui           = true
log_level    = "Info"
EOF

sed -i "s/TRANSIT_NODE_ID/vault-transit-${TRANSIT_NODE_ID}/g" /etc/vault/vault.hcl
sed -i "s/AWS_REGION/${AWS_REGION}/g" /etc/vault/vault.hcl
sed -i "s/KMS_KEY_ID/${KMS_KEY_ID}/g" /etc/vault/vault.hcl

# Generate self-signed certificates
mkdir -p /etc/vault/certs
cd /etc/vault/certs

openssl req -new -x509 -days 365 -nodes \
  -out vault.crt -keyout vault.key \
  -subj "/CN=vault-transit-${TRANSIT_NODE_ID}.internal"

chmod 600 vault.key
chown vault:vault vault.crt vault.key

# Create systemd service
cat > /etc/systemd/system/vault.service << 'EOF'
[Unit]
Description=HashiCorp Vault (Transit)
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
SyslogIdentifier=vault-transit

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vault
systemctl start vault

echo "Waiting for Transit cluster to unseal..."
for i in {1..30}; do
  if /opt/vault/vault status -address=https://127.0.0.1:8200 2>/dev/null | grep -q "Sealed.*false"; then
    echo "✓ Transit cluster unsealed successfully"
    break
  fi
  echo "Attempt $i: Waiting for unseal..."
  sleep 2
done

echo "=== Vault Transit Bootstrap Completed at $(date) ==="
