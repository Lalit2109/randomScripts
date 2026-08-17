# Testing Strategy — Single Function App / Key Vault Pilot

Goal: prove the full migration pattern end-to-end against **one** Function App and its dedicated Key Vault before it becomes the template for RolloutPlan.md's phased rollout. Do not skip steps or batch them — this pair is the reference implementation everything else is validated against.

## Pre-checks

- [ ] Confirm the pilot Function App's identity type (system- or user-assigned) and that it currently has a working `Key Vault Secrets User` (or equivalent access policy) role assignment — do **not** change this as part of the pilot; the migration must not touch identity/RBAC.
- [ ] Confirm `vnetRouteAllEnabled` (or `WEBSITE_VNET_ROUTE_ALL`) is `true` on the pilot Function App — if not, fix this first (Design.md §2.1), otherwise the Service Endpoint will have no effect and the test will give a false result.
- [ ] Capture baseline: current Key Vault firewall config, current Private Endpoint details (subnet, private IP, DNS record), current Diagnostic Settings (if any), current secret retrieval success rate/latency from Application Insights if available.
- [ ] Confirm a rollback path is understood and ready before starting (Architecture.md §7) — this is a test, treat it as reversible by design, not "should be fine."
- [ ] Notify the pilot Function App's owning team of the test window.

## Enable Service Endpoint

- [ ] Identify the pilot Function App's integration subnet (`az functionapp vnet-integration list`).
- [ ] Run `scripts/migration/Enable-ServiceEndpoint.ps1 -SubnetId <subnet-id>`, adding `Microsoft.KeyVault` to the subnet's service endpoints. This is additive and non-destructive — existing traffic (including the still-active Private Endpoint) is unaffected. The script snapshots the subnet's prior config to `scripts/migration/snapshots/` first.
- [ ] Confirm via `az network vnet subnet show` that `serviceEndpoints` now includes `Microsoft.KeyVault`.

## Configure Firewall

- [ ] Run `scripts/migration/Set-KeyVaultFirewall.ps1 -VaultName <vault> -AddSubnetId <subnet-id>` to add a VNet rule for the pilot subnet. **Do not yet** change `default_action` or remove the Private Endpoint — both access paths coexist at this point (the script's `-AddSubnetId` mode only adds a rule, it doesn't touch `default_action`). The script snapshots the vault's prior firewall config first.
- [ ] Confirm via `az keyvault show` that the VNet rule is present.

## Validate Managed Identity

- [ ] Confirm no RBAC/access-policy change was made (diff against pre-check baseline) — the point of this test is proving the network layer works with identity unchanged.
- [ ] `az keyvault show --query properties.networkAcls` — confirm the vault's ACL now includes the pilot subnet.

## Test Secret Retrieval — via Service Endpoint, PE still present

- [ ] Trigger the Function App (via its normal invocation path — HTTP trigger call, queue message, or a manual test invocation) and confirm secret retrieval succeeds. At this point traffic may still resolve via the Private DNS Zone override to the Private Endpoint's private IP — this step primarily confirms nothing broke by adding the VNet rule, not yet that the Service Endpoint path specifically works.
- [ ] To specifically validate the Service Endpoint path (not just "it still works via the PE"), temporarily test from a VM/container in the same subnet with the Private DNS Zone **not** linked (or use `nslookup`/`Resolve-DnsName` to confirm what the subnet currently resolves the vault's FQDN to) — if it still resolves to the private IP, the PE is still in the path and the Service Endpoint hasn't been proven independently yet. This is expected at this stage; the independent proof happens after PE removal (see below).

### Testing directly from the Function App (Kudu/SSH console)

An alternative to "temporarily test from a VM/container in the same subnet" above:
test from the Function App's own execution environment directly, via its Kudu
console — this runs in the exact real network context (VNet integration,
outbound routing) rather than an approximation of it, and needs no separate VM.

**Getting a console**: Portal → your Function App → **Development Tools** →
**Console** (Windows) or **SSH** (Linux) — or go straight to
`https://<function-app-name>.scm.azurewebsites.net/DebugConsole` (Windows Kudu)
or use the **SSH** blade for Linux plans.

**1. DNS check** — resolves to a private IP → still going via the Private
Endpoint's DNS override (PE still effectively in the path, expected before PE
removal); resolves to a public IP → going out publicly, gated by the Service
Endpoint firewall rule (the mechanism itself doesn't change the destination
address, it authorizes the source subnet):

```powershell
# Windows Kudu (PowerShell console)
Resolve-DnsName <vault-name>.vault.azure.net
```
```bash
# Linux (SSH). If nslookup/dig aren't installed in the container, curl's
# verbose connection log shows the resolved IP without needing them:
nslookup <vault-name>.vault.azure.net || curl -v https://<vault-name>.vault.azure.net 2>&1 | grep -i "Trying"
```

**2. Network reachability only** (no auth) — isolates whether a failure is the
*firewall/network* layer or the *identity/authorization* layer (Architecture.md's
"two independent controls" model — this tells you which one to look at):

```powershell
# Windows
Test-NetConnection -ComputerName <vault-name>.vault.azure.net -Port 443
```
```bash
# Linux
curl -v --max-time 5 "https://<vault-name>.vault.azure.net" 2>&1 | grep -E "Connected to|Trying"
```

**3. Full end-to-end test** — acquire a token for the Function App's own Managed
Identity via the platform's Instance Metadata Service, then call Key Vault
directly. This proves network + DNS + firewall + identity + authorization all
in one shot, without needing to trigger an actual function execution:

```powershell
# Windows Kudu PowerShell console
$token = (Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https://vault.azure.net' -Headers @{Metadata="true"}).access_token
try {
    $r = Invoke-WebRequest -Uri "https://<vault-name>.vault.azure.net/secrets/<secret-name>?api-version=7.4" -Headers @{Authorization="Bearer $token"}
    Write-Host "SUCCESS: HTTP $($r.StatusCode)"
} catch {
    Write-Host "FAILED: HTTP $($_.Exception.Response.StatusCode.value__)"
}
```
```bash
# Linux SSH console - grep-based token extraction, no jq/python dependency assumed
TOKEN=$(curl -s 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https://vault.azure.net' -H Metadata:true | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
curl -s -o /dev/null -w "HTTP %{http_code}\n" "https://<vault-name>.vault.azure.net/secrets/<secret-name>?api-version=7.4" -H "Authorization: Bearer $TOKEN"
```
`200` = full success. `403` = network path is fine, authorization is the
problem (RBAC/Access Policy). Connection timeout/refused before you even get an
HTTP status = firewall/network layer is the problem. Deliberately checking
status code only (`-o /dev/null`), not the response body, so the secret's
actual value never appears in a console session that might be logged — drop
that flag only if you specifically need to confirm the value itself.

Run this for both of the pilot Key Vaults, once with the Private Endpoint still
present and again after removal (§"Remove Private Endpoint" below), to directly
compare the two states rather than inferring it from Function App logs alone.

## Verify Logs

- [ ] Confirm the Key Vault's Diagnostic Setting (deploy it now if not already present — see Configure Firewall step and Design.md §6) is sending `AuditEvent` logs to Log Analytics.
- [ ] Query Log Analytics for the test invocation's `SecretGet`/`CertificateGet` events, confirm caller identity matches the Function App's Managed Identity, and confirm the source IP/network context is present in the log entry.
```kql
AzureDiagnostics
| where ResourceType == "VAULTS" and OperationName == "SecretGet"
| where TimeGenerated > ago(1h)
| project TimeGenerated, CallerIPAddress, identity_claim_appid_g, ResultType
```

## Verify Policies

- [ ] Confirm the pilot Key Vault (still mid-transition, PE + firewall VNet rule both present) does **not** yet trip the `deny-private-endpoint-creation-post-migration` policy — it should either be excluded (not yet in migrated scope) or that policy should still be in `Audit`/`DoNotEnforce` mode for the pilot subscription at this stage (Design.md §7).
- [ ] Confirm the `audit-keyvault-diagnostic-settings-missing` policy shows compliant now that the Diagnostic Setting exists.
- [ ] Confirm soft delete and purge protection audits are compliant (should already be, unrelated to this migration, but verify).

## Remove Private Endpoint

- [ ] Run `scripts/migration/Set-KeyVaultFirewall.ps1 -VaultName <vault> -DefaultAction Deny` (if not already) — with the VNet rule already validated as working, this is now safe.
- [ ] Run `scripts/migration/Remove-PrivateEndpoint.ps1 -VaultName <vault>`, which snapshots the Private Endpoint's full configuration (subnet, private IP, DNS zone group) to `scripts/migration/snapshots/` for restore, then removes the Private Endpoint resource and its associated Private DNS Zone record — see Architecture.md §7.
- [ ] Confirm via `nslookup`/`Resolve-DnsName` from within the subnet that the vault's FQDN now resolves to its **public** IP (no more Private DNS override) — this is the point where the Service Endpoint path is truly independently proven, since there is no longer a private path to fall back to.

## Repeat Tests

- [ ] Re-run **Test Secret Retrieval** exactly as before, now with the Private Endpoint gone. Success here is the real proof point.
- [ ] Re-run **Verify Logs** — confirm continued successful `SecretGet` events, now unambiguously over the Service Endpoint path.
- [ ] Re-run **Verify Policies** — confirm `deny-private-endpoint-creation-post-migration` would now correctly block a new PE against this vault (test by attempting one in a non-prod validation, expecting a policy-denied error), and confirm `deny-keyvault-without-vnet-rules`/`deny-keyvault-without-default-deny` show this vault as compliant.
- [ ] Run a negative test: from a subnet **not** on the allow-list, confirm the Key Vault correctly rejects the request (`403`) — proves the firewall is actually restrictive, not just present.
- [ ] Let the Function App run under normal load for an observation window (recommend minimum 24–48 hours) before declaring the pilot complete, watching for cold-start-related failures, intermittent DNS caching issues, or any latency regression.

## Rollback Steps (if any step above fails)

1. If firewall/VNet rule causes access failure: re-widen firewall (temporarily add prior state back, or set `default_action = "Allow"` as an immediate break-glass step with the Activity Log Alert expected to fire) while root-causing.
2. If root cause is a missing/misconfigured Service Endpoint: fix and retest before reverting anything else.
3. If unresolvable within the test window: re-deploy the Private Endpoint module for this Key Vault, restore the Private DNS Zone record, restore `default_action` to its pre-test state. Document the failure mode found — this directly feeds a Design.md update before attempting the pilot again.

## Success Criteria

All of the following must be true before this pattern is approved to proceed to RolloutPlan.md Phase 1:
- [ ] Secret retrieval succeeds reliably with **no** Private Endpoint present, over multiple invocations across the observation window.
- [ ] Diagnostic logs correctly capture every access with correct caller identity and network context.
- [ ] Negative test (disallowed subnet) is correctly rejected.
- [ ] All relevant Azure Policies show the pilot Key Vault as compliant.
- [ ] No RBAC/Managed Identity change was required at any point.
- [ ] No unexpected latency/error-rate regression versus the pre-migration baseline.
- [ ] Rollback was demonstrated to work (either exercised for real due to a failure, or a dry run of the `Restore-*` scripts against the pilot's saved snapshots).
