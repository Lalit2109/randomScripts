# Pipelines

Both pipelines are manual-trigger only (`trigger: none`) — this is a CAB-gated, human-approved change process (`docs/RolloutPlan.md`), never automated on a code push.

| Pipeline | When to run |
|---|---|
| `keyvault-migration-onboard-subscription.yml` | Once per subscription, before its first migration batch — deploys monitoring and the Policy Initiative assignment |
| `keyvault-migration-batch.yml` | Once per migration batch (a subnet's worth of Key Vaults) — re-validates discovery, then runs the migration scripts in order with an environment-level approval gate standing in for CAB sign-off |

Both pipelines use Azure DevOps **Environments** with approval checks configured outside this YAML (in the Azure DevOps project settings) as the actual CAB/sign-off enforcement mechanism — `environment: keyvault-migration-<scope>` in each pipeline is the hook point for that.

Every batch run publishes its `scripts/migration/*.ps1` snapshot output as a pipeline artifact (`rollback-snapshots-*`) — this is the rollback source of truth (`docs/Architecture.md` §7), so **do not delete pipeline run artifacts** for a subscription until `docs/RolloutPlan.md`'s exit criteria confirm it's safe to do so.
