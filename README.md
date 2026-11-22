# CaribeShop

## Key Vault demo

Terraform 1.11 or newer is required for the write-only secret input.

The VM Scale Set reads the `caribeshop-demo` secret through its system-assigned
managed identity. The Key Vault allows the VM subnet and the Terraform
operator's public IPv4 address (`/32`); all other network access is denied.
The VM identity receives only the **Key Vault Secrets User** role. Terraform's
identity receives **Key Vault Secrets Officer** on this vault to provision and
rotate the demo secret. Increment `value_wo_version` in `terraform/main.tf`
when rotating the write-only secret value.

Before running Terraform, provide these local inputs:

- `operator_ipv4_cidr`: the operator's current public IPv4 address in `/32`
  notation.
- `demo_secret_expires_at`: a future RFC3339 timestamp.
- `demo_secret_value`: a locally generated demo value of at least 16 characters.
  Supply it through `TF_VAR_demo_secret_value` or an ignored local tfvars file;
  never commit or print it.

The secret uses the provider's write-only `value_wo` argument, so its value is
not stored in Terraform state. Keep the remote state and local Terraform inputs
protected regardless.

After deployment, `terraform output -raw secret_check_url` returns an endpoint
that reports only the secret length and a truncated SHA-256 fingerprint. It
never returns the secret value.

The endpoint and proxy are installed by cloud-init. Existing VMSS instances
must receive the updated model and be reimaged or replaced in a controlled,
one-at-a-time rollout before testing the endpoint.

## Policy and Key Vault audit logs

The resource group has a Deny policy that rejects Key Vaults unless both RBAC
authorization and purge protection are enabled. Key Vault `AuditEvent` logs are
sent to the `AZKVAuditLogs` table in the `law-caribeshop` workspace for 30 days.

Use this query to verify secret reads by the VMSS managed identity:

```kusto
AZKVAuditLogs
| where OperationName == "SecretGet"
| where tostring(Identity) contains "<VMSS principal ID>"
| project TimeGenerated, OperationName, ResultType, CallerIpAddress, Identity
| order by TimeGenerated desc
```
