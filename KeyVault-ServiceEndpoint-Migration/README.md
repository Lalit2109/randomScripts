# Key Vault Private Endpoint → Service Endpoint Migration

Production-ready design and implementation package for migrating Azure Key Vault networking from **Private Endpoints** to **Virtual Network Service Endpoints**, across an estate of hundreds of Azure Function Apps (one Key Vault per Function App), rolled out across multiple subscriptions.

## Why this migration

At the current scale (hundreds of Key Vaults, each with its own Private Endpoint), the Private Endpoint model carries real operational overhead: one NIC and private IP per Key Vault, Private DNS zone record management at scale, and per-resource network plumbing that has to be replicated for every new Function App. Service Endpoints remove that per-resource networking footprint — the control point moves from "does a private IP exist for this resource" to "is this subnet, and only this subnet, on the Key Vault's firewall allow-list."

**Read this first:** [`docs/Architecture.md`](docs/Architecture.md) — section "Security Posture Change" explains explicitly what is gained and what is given up by this move. This is a legitimate, supportable design for this scenario, but it is a different security model than Private Link, not a strictly stronger one. Everyone approving this rollout should read that section before sign-off.

**No Terraform for the migration itself.** Every Function App and Key Vault already exists — this is a networking-configuration change against live resources, not a greenfield deployment. Migration is executed via idempotent Azure CLI/PowerShell scripts (`scripts/migration/`) run through the existing Azure DevOps pipeline, each snapshotting the pre-change configuration to JSON as the rollback point. See `Architecture.md` §2 and §7 for why.

**The Azure Policies are the one deliberate exception** (`policies/terraform/`) — they're net-new declarative objects with no pre-existing live state to reconcile against, a good fit for Terraform, and this org's policy estate is Terraform-managed elsewhere already. See `policies/terraform/README.md`.

## Repository structure

```
KeyVault-ServiceEndpoint-Migration/
│
├── docs/
│   ├── Architecture.md              Design rationale, diagrams, risks, rollback
│   ├── Design.md                    Discovery, networking plan, firewall & SE policy design, monitoring, policy design
│   ├── RolloutPlan.md               Enterprise phased rollout (pilot → dev → non-prod → prod)
│   ├── BusinessImplementationPlan.md Stakeholder-facing plan, RACI, Go/No-Go
│   ├── Runbook.md                   Step-by-step operational runbook
│   ├── Testing.md                   Single Function App / Key Vault pilot test plan
│
├── policies/                        Azure Policy definitions + initiative + assignment
│   └── terraform/                   Terraform (the one exception to "no Terraform" above)
├── scripts/
│   ├── discovery/                   Discovery (CLI/PowerShell/Resource Graph queries)
│   └── migration/                   Migration + rollback scripts, snapshots/ output
├── diagrams/                        Mermaid diagram sources (also embedded in docs)
├── pipelines/                       Azure DevOps YAML pipeline (runs the migration scripts)
└── README.md                        This file
```

## Reading order

1. `docs/Architecture.md` — understand the "why" and the trade-offs before anything else.
2. `docs/Design.md` — the full technical design: discovery, networking, firewall, Service Endpoint Policy limitations, monitoring, Azure Policy.
3. `docs/Testing.md` — validate the design against one Function App / Key Vault pair.
4. `docs/RolloutPlan.md` — scale the validated pattern to hundreds of Function Apps across subscriptions.
5. `docs/BusinessImplementationPlan.md` — the stakeholder/CAB-facing version of the same plan.
6. `docs/Runbook.md` — keep this open during actual execution.

## Prerequisites

- Azure CLI ≥ 2.55 with the `resource-graph` extension
- PowerShell 7+ with the `Az` module ≥ 11.0
- `Owner` or `User Access Administrator` + `Key Vault Data Access Administrator` on target subscriptions for the pilot; scoped custom roles for wider rollout (see `docs/Runbook.md`)
- An existing Azure DevOps project with a service connection scoped per target subscription
