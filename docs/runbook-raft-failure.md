# Runbook: Handle Raft Member Failure

## Overview

This runbook describes how to handle a failed Vault node in the HA cluster. The process is mostly automated, but operator oversight is required.

**Decision tree:**
- Is the node still visible in the cluster? → Try to restart it
- Is it hard-dead (unreachable)? → Remove it and replace it
- Is it stuck in an inconsistent state? → Force-remove and rebuild

---

## Quick Diagnosis

### Step 1: Identify Which Node Failed

```bash
# Check cluster health from a healthy node
ssh vault-aws-2.internal

vault operator raft autopilot state

# Expected output:
# Name                     State       Address
# vault-aws-1              alive       10.0.1.10:8201
# vault-aws-2              alive       10.0.1.11:8201   (this is YOU)
# vault-aws-3              dead        10.0.1.12:8201   ← FAILED NODE

# Also check node-by-node
vault operator raft list-peers

# Should show:
# Node            Address              State       Leader
# vault-aws-1     10.0.1.10:8201       follower    false
# vault-aws-2     10.0.1.11:8201       leader      true
# vault-aws-3     10.0.1.12:8201       dead        false
```

### Step 2: Check Node Status

```bash
# Try to SSH into the failed node
ssh vault-aws-3.internal

# If SSH works:
  # Check if Vault is running
  systemctl status vault
  
  # Check logs for errors
  tail -100 /var/log/vault/vault.log
  
  # If Vault is crashed, try to restart
  systemctl restart vault
  
  # Wait 30 seconds, then check if it rejoined
  sleep 30
  vault operator raft list-peers
  
  # If it came back → Issue resolved, no further action needed

# If SSH fails or times out:
  # Node is hard-dead (network unreachable, instance crashed)
  # → Proceed to "Remove Dead Node" below
```

---

## Remove Dead Node (If Restart Didn't Work)

### Step 3: Remove the Dead Node from Cluster

```bash
# From a healthy node (e.g., vault-aws-2)
ssh vault-aws-2.internal

# Remove the failed node from Raft membership
vault operator raft remove-peer vault-aws-3

# Verify removal
vault operator raft list-peers

# Expected: only 2 nodes listed (vault-aws-1, vault-aws-2)
# The cluster now operates on 2/2 nodes (still quorum: 2 = majority of 2)

# Note: If you have 3 nodes and remove 1, you have 2 nodes with quorum = 2.
# This is safe temporarily, but you MUST rebuild the third node quickly.
# (With only 2 nodes, any single failure brings down the cluster)
```

**Important:** After removing a node, you MUST rebuild it within 24 hours. Operating with only 2/3 nodes risks complete cluster failure.

---

## Rebuild the Failed Node (Automatic)

### Step 4: Destroy and Recreate the Instance

```bash
# From your workstation (where Terraform is)
cd terraform/aws

# Destroy the failed instance
terraform destroy -target=aws_instance.vault_node[2]

# This terminates vault-aws-3. Confirm when prompted.
# The instance will shut down cleanly.

# Rebuild it
terraform apply -target=aws_instance.vault_node[2]

# Wait ~3 minutes for the instance to:
# 1. Boot
# 2. Run cloud-init (install Vault)
# 3. Unseal via KMS (automatic)
# 4. Rejoin the cluster (automatic)

# Verify it rejoined
vault operator raft list-peers

# Expected: all 3 nodes present, the new node is "follower"
# Node            Address              State       Leader
# vault-aws-1     10.0.1.10:8201       follower    false
# vault-aws-2     10.0.1.11:8201       leader      true
# vault-aws-3     10.0.1.13:8201       follower    false  ← NEW ADDRESS
```

---

## Verify Recovery

### Step 5: Confirm Cluster Health

```bash
# Run full health check
vault operator raft autopilot state

# Expect:
# - 3 nodes healthy
# - 1 leader elected
# - No unhealthy followers

# Check cluster can serve requests
vault status

# Should show:
# Cluster Name: vault-aws
# HA Enabled: true
# HA Mode: active (if you're the leader) or standby
# Sealed: false
# Unseal Progress: 0/0  ← No manual unsealing needed
```

### Step 6: Monitor for Recovery Lag

The newly-rejoined node will catch up on missed raft entries. This usually takes <30 seconds for smaller deployments, but can take longer if there was high write volume during the outage.

```bash
# Monitor raft replication lag
watch -n 1 'vault operator raft autopilot state | grep -E "vault-aws-3|commit_index"'

# Look for raft.apply metric in Datadog to see replication latency
```

---

## If Node Won't Rejoin (Stuck State)

### Scenario: Node Keeps Crashing After Rebuild

```bash
# You destroyed and recreated the instance, but Vault keeps exiting with:
# "Failed to recover from snapshot"
# or
# "Duplicate peer ID"

# This happens if the old node's data persists.
```

### Fix: Clean Data Directory

```bash
# SSH into the problematic node
ssh vault-aws-3.internal

# Stop Vault
sudo systemctl stop vault

# Backup the raft directory (just in case)
sudo cp -r /mnt/vault/raft /mnt/vault/raft.backup-$(date +%s)

# Delete all raft data
sudo rm -rf /mnt/vault/raft/*

# Restart Vault (it will rejoin from scratch)
sudo systemctl start vault

# Wait 30 seconds for unseal + rejoin
sleep 30

# Verify
vault operator raft list-peers
# Should now show the new node with fresh identity
```

---

## If You Need to Force-Remove a Node

### Nuclear Option (Use Only If Stuck)

**This is dangerous and can cause data loss. Use only if you can't remove the node normally.**

```bash
# From a healthy node
ssh vault-aws-2.internal

# Forcefully remove the peer (bypassing normal consensus)
vault operator raft remove-peer -force vault-aws-3

# This removes the node ID from cluster state WITHOUT consensus.
# It's safe only because we have 2/2 nodes (both can agree it's gone).
# DO NOT do this with 1 node left (you'll have a zombie cluster).
```

---

## Validation Checklist

After recovery, verify:

- [ ] All 3 nodes present: `vault operator raft list-peers | wc -l` (should be 3)
- [ ] All nodes marked "alive": `vault operator raft autopilot state | grep -c "alive"` (should be 3)
- [ ] Cluster has leader: `vault status | grep "HA Mode"` (should show "active" or "standby")
- [ ] Can read secrets: `vault kv get secret/test` (should return value)
- [ ] Can write secrets: `vault kv put secret/test value=newvalue` (should succeed)
- [ ] Monitoring shows healthy: Datadog dashboard shows 3 healthy nodes
- [ ] No errors in logs: `tail /var/log/vault/vault.log | grep ERROR` (should be empty)

---

## Timeline: How Long Does This Take?

| Step | Duration | Notes |
|------|----------|-------|
| Detect failure | ~10-30s | Depends on your monitoring |
| Restart node | ~30s | If restart works, done |
| SSH into node + check logs | ~1-2min | Diagnosis |
| Remove dead node from cluster | ~5-10s | Quick consensus operation |
| Destroy old instance | ~30-60s | Terraform destroy |
| Create new instance | ~2-3min | AWS boot time |
| New instance unseal + rejoin | ~30-60s | Automatic |
| **Total (failed node recovery)** | **~5-10min** | End-to-end |

**No data loss. Cluster keeps operating during entire process.**

---

## Common Mistakes

❌ **Mistake:** Reusing the same IP/hostname before cleaning up old data.  
✅ **Fix:** Always destroy fully before rebuilding, or manually delete `/mnt/vault/raft/*`

❌ **Mistake:** Trying to operate with 1/3 nodes for more than a few hours.  
✅ **Fix:** Rebuild the failed node immediately. Only 2/3 nodes = fragile.

❌ **Mistake:** Restarting the leader when a follower fails.  
✅ **Fix:** Only restart the failed node. Restarting the leader causes unnecessary failover.

❌ **Mistake:** Forgetting to verify the new node rejoined.  
✅ **Fix:** Always run `vault operator raft list-peers` after rebuild.

---

## Escalation

**If recovery doesn't work after 10 minutes:**

1. Check recent Terraform changes (did something break the cluster config?)
2. Review KMS permissions (can the new instance unseal?)
3. Check network connectivity (is the new instance in the right VPC/subnet?)
4. Review Vault logs for cryptic errors
5. If stuck, call the incident response contact (see ONCALL.md)

---

## Post-Incident Review

After any node failure, schedule a brief retrospective:

- **What failed?** (Hardware, software, network)
- **How long was it down?** (RTO = time to recovery)
- **Did clients notice?** (Should have auto-failover)
- **What could we have detected earlier?** (Improve monitoring)
- **What can we prevent next time?** (Update runbook, config, monitoring)

This runbook should be updated based on learnings.

---

## Related Runbooks

- [Seal/Unseal Vault](./runbook-seal-unseal.md)
- [Failover to Secondary Region](./runbook-failover.md)
- [Disaster Recovery](./runbook-disaster-recovery.md)

See [ARCHITECTURE.md](../ARCHITECTURE.md) for detailed failure mode analysis.
