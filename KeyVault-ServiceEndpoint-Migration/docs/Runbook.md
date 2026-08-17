# Operational Runbook

Keep this open during actual execution of any migration batch. References `scripts/` and `policies/` for the concrete artifacts each step uses. Every Function App and Key Vault already exists — this runbook changes network configuration on live resources via idempotent scripts, not an IaC apply.

---

## 1. Discovery

**Trigger**: before every phase, and immediately before every batch within Non-Prod/Production phases (re-validate, don't rely on stale inventory).

```bash
# Full tenant/subscription-scoped discovery
./scripts/discovery/discover-inventory.sh --subscription <sub-id> --output ./inventory/<sub-id>-$(date +%Y%m%d).json
```
```powershell
./scripts/discovery/Discover-Inventory.ps1 -SubscriptionId <sub-id> -OutputPath ./inventory/<sub-id>-$(Get-Date -Format yyyyMMdd).json
```

**Checklist:**
- [ ] Run discovery for the target subscription(s)/subnet(s).
- [ ] Diff against the previous discovery run (if any) — flag any new Key Vault, new Function App, or changed VNet integration since last run.
- [ ] Confirm every Function App in scope has `vnetRouteAllEnabled = true` (Design.md §2.1) — flag and fix any that don't before proceeding.
- [ ] Confirm the exclusion list (Key Vaults staying on Private Endpoint) is up to date and every excluded vault has a recorded reason and sign-off.
- [ ] Output the consolidated inventory to the batch's working folder — this becomes the exact scope list for the CAB submission and the `-BatchInventory` input to every migration script for this batch.

---

## 2. Deployment

**Trigger**: after discovery is confirmed and CAB approval (Non-Prod/Prod) is obtained.

**Order of operations per batch (subnet-by-subnet, per Design.md §2.5):**

1. **Enable Service Endpoint on the subnet** (non-destructive):
   ```powershell
   ./scripts/migration/Enable-ServiceEndpoint.ps1 -SubnetId <subnet-id> -SnapshotDir ./snapshots
   ```
2. **Verify** the subnet shows `Microsoft.KeyVault` in its service endpoints before proceeding.
3. **For the first Key Vault on this subnet**: add the VNet rule alongside the existing Private Endpoint (both active). This also sets the `kv-se-migration-scope=true` tag automatically (v2+) - no separate manual tagging step:
   ```powershell
   ./scripts/migration/Set-KeyVaultFirewall.ps1 -VaultName <vault> -AddSubnetId <subnet-id> -SnapshotDir ./snapshots
   ```
4. **Validate** (see §3 below) before touching the Private Endpoint.
5. **Remove the Private Endpoint** for that Key Vault only after validation passes:
   ```powershell
   ./scripts/migration/Set-KeyVaultFirewall.ps1 -VaultName <vault> -DefaultAction Deny -SnapshotDir ./snapshots
   ./scripts/migration/Remove-PrivateEndpoint.ps1 -VaultName <vault> -SnapshotDir ./snapshots
   ```
6. **Repeat steps 3–5** for the remaining Key Vaults on this subnet, batching once the pattern is confirmed stable (no need to fully serialize after the first one or two on a given subnet).
7. **Move to the next subnet.**

All changes ship through the Azure DevOps pipeline (`pipelines/`), which invokes these same scripts and publishes each run's `-SnapshotDir` output as a pipeline artifact — no ad-hoc script execution from a workstation against Non-Prod/Prod. Pilot phase may run scripts locally for speed, per `Testing.md`, provided the resulting snapshots are still committed/retained.

---

## 3. Validation

Run after every individual Key Vault's Private Endpoint removal (step 5 above), not just at batch end:

- [ ] Trigger the Function App and confirm successful secret retrieval (`Testing.md` "Test Secret Retrieval").
- [ ] Query Log Analytics for the corresponding `SecretGet` event with the expected caller identity (`Testing.md` "Verify Logs" query).
- [ ] Confirm `az keyvault show` reflects `default_action = Deny`, the correct VNet rule, and no remaining Private Endpoint connection.
- [ ] Confirm Azure Policy compliance state for this Key Vault (`az policy state list --resource <vault-id>`).

If any check fails, go to §5 Rollback immediately — do not proceed to the next Key Vault in the batch until resolved.

---

## 4. Monitoring

**Standing checks, not one-time:**
- [ ] Confirm the shared Action Group's alert routing is live (send a test notification via `az monitor action-group test-notifications create`).
- [ ] Confirm each of the eight Activity Log Alerts (Design.md §6.2) shows `Enabled = true` for the scope covering this batch's subscriptions.
- [ ] Confirm Diagnostic Settings are present and actively ingesting for every migrated Key Vault (spot-check via Log Analytics query, not just resource existence).
- [ ] During the post-batch observation window (24–48h minimum per `Testing.md`), monitor for: `403` spikes in Key Vault audit logs, Function App execution failures correlated with Key Vault calls, and any Activity Log Alert firing unexpectedly.

---

## 5. Rollback

Follow `Architecture.md` §7 precisely. Quick reference:

**Firewall-only issue** (access broken, PE already removed or not yet):
```powershell
# Break-glass: temporarily widen access while root-causing (expect the Activity Log Alert to fire - that's correct behavior)
./scripts/migration/Set-KeyVaultFirewall.ps1 -VaultName <vault> -DefaultAction Allow -SnapshotDir ./snapshots
```
Root-cause, fix the actual VNet rule/Service Endpoint config, then restore from the pre-incident snapshot:
```powershell
./scripts/migration/Restore-KeyVaultFirewall.ps1 -VaultName <vault> -SnapshotPath ./snapshots/<vault>-firewall-<timestamp>.json
```
Never leave a vault in `Allow` as a standing state; treat it as a timed exception with a follow-up ticket to close it out same-day.

**Full rollback to Private Endpoint** for a specific Key Vault:
```powershell
./scripts/migration/Restore-PrivateEndpoint.ps1 -VaultName <vault> -SnapshotPath ./snapshots/<vault>-pe-<timestamp>.json
./scripts/migration/Restore-KeyVaultFirewall.ps1 -VaultName <vault> -SnapshotPath ./snapshots/<vault>-firewall-<timestamp>.json
```
Confirm DNS resolution returns to the private IP before declaring rollback complete.

**Escalation**: if rollback itself fails or the issue is systemic (affecting more than one Key Vault), pause the current batch (`RolloutPlan.md` "Phase-level pause") and escalate to the platform team lead before any further changes.

---

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `403 Forbidden` from Key Vault after migration | Service Endpoint not actually active on the subnet, or `vnetRouteAllEnabled` is `false` so traffic doesn't route through the integrated subnet | Confirm `az network vnet subnet show` shows the service endpoint; confirm Function App outbound VNet routing setting |
| `403 Forbidden`, Service Endpoint confirmed active | Firewall VNet rule references the wrong subnet ID, or a stale/cached firewall config | Re-verify `az keyvault show` VNet rule subnet ID matches exactly; note firewall rule changes can take a few minutes to propagate |
| Intermittent failures right after PE removal | DNS caching — client/runtime still has the old private IP cached from the Private DNS Zone override | Restart the Function App (forces DNS re-resolution); confirm Private DNS Zone record was actually removed, not just the PE resource |
| Secret retrieval works but is slower than before | Traffic path change (was private IP direct, now via public endpoint over backbone) — usually negligible, but check for an NVA/route table hairpin (Design.md §2.3) adding hops | Review the subnet's route table for unexpected UDRs; this is a one-time investigation per subnet, not per Key Vault |
| Azure Policy shows a migrated Key Vault as non-compliant unexpectedly | Exclusion list parameter not updated, or the vault is missing a required tag used for policy scoping | Check `excludedVaultIds` initiative parameter and the vault's migration-scope tag |
| Activity Log Alert didn't fire for a known firewall change | Alert scope doesn't cover the resource's subscription, or Action Group misconfigured | Verify alert scope and Action Group test-notification |
| CAB-approved batch can't proceed — subnet has an unexpected additional dependency discovered mid-batch | Discovery gap | Halt the batch, re-run discovery for that subnet specifically, update the migration inventory, re-assess before resuming |

---

## 7. Post-Deployment Verification

Run at the end of every batch, and again at the end of every phase (`RolloutPlan.md` exit criteria):

- [ ] Every Key Vault in the batch: no Private Endpoint remains, `default_action = Deny`, correct VNet rule present, Diagnostic Settings active.
- [ ] Policy compliance report for the batch's scope shows 100% compliant (or documented exceptions only).
- [ ] No open incidents attributable to the batch.
- [ ] Discovery inventory updated to reflect the new state (source of truth for the next batch/phase).
- [ ] Batch summary logged (Key Vaults migrated, any issues encountered, resolution) — feeds the phase-level report in `BusinessImplementationPlan.md`'s success metrics tracking.
