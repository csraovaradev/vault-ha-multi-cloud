# vault-ha-multi-cloud

This is a reference design for a highly available Vault cluster on AWS
and OCI, with KMS auto-unseal.

> **Status: untested reference design.** This Terraform has never been
> applied to a real account. Read it as a design to learn from, not as
> something to deploy as is. See [Known gaps](#known-gaps).

## What the Terraform creates

**AWS (`terraform/aws`, default region us-west-2)**
- A VPC with three public and three private subnets and NAT gateways.
- Three Vault nodes (default `m5.large`) in the private subnets, using
  integrated Raft storage with `retry_join`.
- A KMS key that the nodes use for auto-unseal (`seal "awskms"`).
- A separate three-node Vault cluster intended for transit auto-unseal.

**OCI (`terraform/oci`, default region us-phoenix-1)**
- A VCN with public and private subnets and a NAT gateway.
- Three Vault nodes (default `VM.Standard.E4.Flex`, 2 OCPUs, 8 GB),
  using integrated Raft storage.
- An OCI KMS vault and key for auto-unseal (`seal "ocikms"`).

The two clusters are independent. Nothing replicates between them.

## Repo layout

```
ARCHITECTURE.md                  Design notes and failure modes
DEPLOYMENT.md                    Deployment walkthrough
docs/runbook-raft-failure.md     Replacing a failed Raft member
terraform/aws/
  main.tf                        Network, IAM, KMS, Vault and transit instances
  variables.tf
  prod.tfvars                    Example values
  user-data.sh                   Vault node bootstrap
  user-data-transit.sh           Transit node bootstrap
terraform/oci/
  main.tf                        Network, KMS, Vault instances
  variables.tf
  user-data.sh                   Vault node bootstrap
```

## Known gaps

- **Never applied.** This code has not been run against a real account.
  Expect errors on first apply.
- **Transit cluster is not wired in.** The AWS transit cluster is
  created, but the main cluster unseals through KMS and does not use it.
  OCI has no transit cluster.
- **Self-signed TLS.** Each node generates its own certificate at boot,
  so nodes will not trust each other without further work.
- **Network exposure.** The AWS Vault security group has a rule open to
  `0.0.0.0/0`, and the nodes are given Elastic IPs. Restrict both before
  any real use.
- **Vault 1.15.0** is pinned and is not current.
- **No performance, cost or recovery-time figures.** None have been
  measured.

## How to try it

Requires Terraform 1.0 or later and credentials for the cloud you are
targeting. Start with `plan`, and expect to fix things before `apply`
works.

```bash
git clone https://github.com/csraovaradev/vault-ha-multi-cloud.git

cd vault-ha-multi-cloud/terraform/aws
terraform init
terraform plan -var-file="prod.tfvars"

cd ../oci
terraform init
terraform plan -var="compartment_ocid=<your compartment OCID>" \
               -var="ssh_public_key=<your public key>"
```

These resources cost money while they exist. Run `terraform destroy`
when you are done.

## Further reading

- [ARCHITECTURE.md](./ARCHITECTURE.md): design and failure modes
- [DEPLOYMENT.md](./DEPLOYMENT.md): deployment walkthrough
- [Raft member failure runbook](./docs/runbook-raft-failure.md)
