# Discovery Scripts

1. **Run discovery** to build the raw inventory:
   ```bash
   ./discover-inventory.sh --subscription <sub-id-1> --subscription <sub-id-2> --output ./inventory.json
   ```
   or
   ```powershell
   ./Discover-Inventory.ps1 -SubscriptionId sub-id-1,sub-id-2 -OutputPath ./inventory.json
   ```
   Produces one JSON file with five arrays: `keyVaults`, `functionApps`, `privateEndpoints`, `subnets`, `rbacAssignments` — the raw output of the queries in `queries/*.kql`.

2. **Build the migration scope** (one row per Key Vault, joined to its Function App/subnet/existing PE):
   ```powershell
   ./Build-MigrationScope.ps1 -InventoryPath ./inventory.json -OutputCsv ./migration-scope.csv
   ```
   This is the exact scope list used for CAB submissions and as the `-BatchInventory` input to the scripts in `scripts/migration/`. Rows flagged `ReviewRequired = true` (no unique Function App identity match found) must be resolved manually before being included in any batch — never guess the mapping.

3. Re-run both steps immediately before every migration batch (`Runbook.md` §1) — don't rely on a stale inventory, especially in Non-Prod/Production phases where new Key Vaults/Function Apps may have been added since the last run.

## Files

- `queries/*.kql` — individual Resource Graph queries, also usable standalone in the Azure Portal's Resource Graph Explorer or via `az graph query -q "$(cat queries/keyvaults.kql)"`.
- `discover-inventory.sh` / `Discover-Inventory.ps1` — run all queries and consolidate to one JSON file.
- `Build-MigrationScope.ps1` — join the consolidated inventory into a per-Key-Vault migration scope CSV.
