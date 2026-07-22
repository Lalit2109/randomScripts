# Business Implementation Plan — Key Vault Networking Migration

*Stakeholder-facing summary. For full technical detail see `Architecture.md` and `Design.md`.*

## Executive Summary

Our Azure environment hosts hundreds of Function Apps, each with its own dedicated Key Vault protected today by a Private Endpoint. This model has scaled to the point where the per-Key-Vault networking overhead — dedicated network interfaces, private IP addresses, and DNS records for every single vault — has become a significant and growing operational burden for the cloud engineering team, without a proportional increase in security benefit for this specific use case.

This program migrates Key Vault network access from Private Endpoints to **Virtual Network Service Endpoints**, a supported Microsoft Azure pattern that removes the per-resource networking footprint while keeping traffic on Microsoft's private backbone network and enforcing strict, policy-governed firewall controls on every Key Vault. Access continues to be authenticated via each Function App's existing Managed Identity — **no application code or authentication mechanism changes**.

This is a genuine trade-off, not a pure improvement, and is presented to stakeholders as such: we are trading a small amount of network-layer isolation strength for a substantial, ongoing reduction in operational complexity and management overhead, compensated by stronger firewall governance, full audit logging, and automated policy enforcement than exists today. Full detail on this trade-off is in `Architecture.md` §3 and should be read by any stakeholder involved in the Go/No-Go decision.

## Current State

- Hundreds of Function Apps, each with a dedicated Key Vault.
- Every Key Vault has a Private Endpoint: a dedicated network interface, private IP address, and DNS record.
- This footprint grows linearly with every new Function App and multiplies the surface area the platform team must provision, monitor, and eventually decommission.
- Infrastructure is managed via Terraform through Azure DevOps pipelines.
- No consolidated, tenant-wide Azure Policy governance is currently in place for Key Vault network configuration.

## Proposed State

- Key Vault Private Endpoints are retired in favor of Virtual Network Service Endpoints — a subnet-level setting shared across every Key Vault reachable from that subnet, with zero per-Key-Vault networking resource.
- Every Key Vault firewall is set to deny-by-default, allowing only its own Function App's specific subnet.
- A tenant-wide Azure Policy initiative enforces this configuration automatically and flags drift.
- Full audit logging and alerting is introduced for every Key Vault (a genuine improvement — this does not fully exist today).
- Managed Identity authentication is unchanged.

## Benefits

- **Reduced operational overhead**: eliminates hundreds of network interfaces, private IPs, and DNS records, and the ongoing management burden of provisioning/decommissioning them per Key Vault.
- **Lower cost**: removes Private Endpoint hourly + data-processing charges across the full estate.
- **Stronger, consistent governance**: deny-by-default firewalls and automated Azure Policy enforcement replace ad-hoc, per-resource configuration.
- **Improved visibility**: full audit logging and alerting on every Key Vault, closing a monitoring gap that exists today.
- **Simpler onboarding**: new Function App/Key Vault pairs no longer require dedicated network provisioning — just an existing subnet with the Service Endpoint already enabled.

## Risks

*(Full detail and mitigations in `Architecture.md` §6 and `RolloutPlan.md`)*

- **Network isolation is weaker than Private Endpoint**: the Key Vault's public endpoint remains technically addressable; access is restricted by firewall allow-list rather than true network isolation. This is a deliberate, documented trade-off, not an oversight — mitigated by strict firewall scoping, Managed Identity/RBAC as the authorization boundary, and comprehensive monitoring.
- **No granular network-layer control equivalent to Private Endpoint's isolation** for the highest-sensitivity workloads — mitigated by an explicit exclusion list allowing specific Key Vaults to remain on Private Endpoint where warranted.
- **Migration execution risk at scale** (hundreds of Key Vaults, multiple subscriptions) — mitigated by a phased rollout starting with a single pilot, with validation gates between every phase and a per-Key-Vault rollback path.
- **Dependency surprises** (e.g., an on-premises system relying on today's private network path) — mitigated by a mandatory discovery phase before any Key Vault is migrated.

## Timeline

| Phase | Scope | Estimated Duration |
|---|---|---|
| Pilot | 1 Function App/Key Vault pair + small batch | 1–2 weeks |
| Development | All Dev subscriptions | 3–6 weeks |
| Non-Production | All Staging/UAT/QA subscriptions | 4–8 weeks |
| Production | All Production subscriptions | 8–16+ weeks |

**Total estimated duration: approximately 4–8 months**, dependent on estate size, CAB cadence, and Production risk tolerance. Duration is deliberately outcome-gated (see `RolloutPlan.md` Validation Gates), not calendar-fixed — Production timelines should not be compressed to hit a date at the expense of validation rigor.

## Rollout Phases

See `RolloutPlan.md` for full detail. Summary: Pilot → Development → Non-Production → Production, each gated by explicit technical and governance sign-off before the next phase begins, batched subnet-by-subnet and (in Production) ordered by workload criticality, least-critical first.

## Success Metrics

- 100% of in-scope Key Vaults migrated (or on the signed-off exclusion list) with zero remaining Private Endpoints.
- 100% Azure Policy compliance across the initiative's deny and audit policies, tenant-wide, for in-scope subscriptions.
- Zero migration-attributable Production incidents in the four weeks following program completion.
- Full audit logging and alerting operational on every Key Vault (baseline today: partial/inconsistent).
- Measurable reduction in Private Endpoint-related Azure spend (tracked via cost management, reported at program close).
- Reduced mean-time-to-provision for a new Function App/Key Vault pair (no PE/DNS provisioning step required).

## Responsibilities (RACI)

| Activity | Cloud Platform Engineering | Workload/App Teams | Security & Compliance | Change Advisory Board | Executive Sponsor |
|---|---|---|---|---|---|
| Architecture & design approval | R/A | C | C | I | I |
| Discovery (inventory, dependency mapping) | R/A | C | I | I | I |
| Pilot execution | R/A | C | I | I | I |
| Migration script development (network config changes to existing resources) | R/A | I | I | I | I |
| Azure Policy design & assignment | R/A | I | A/C | I | I |
| Per-phase batch execution | R/A | C | I | A | I |
| CAB submission & approval | R | I | C | A | I |
| Incident response during migration | R/A | C | I | I | I |
| Monitoring/alert response (steady state) | R/A | I | I | I | I |
| Exclusion list sign-off (vaults staying on PE) | R | C | A | I | I |
| Program status reporting | R | I | I | I | A/I |
| Go/No-Go decision per phase | R/A | I | C | C | A |

*(R = Responsible, A = Accountable, C = Consulted, I = Informed)*

## Estimated Effort

| Workstream | Estimated Effort |
|---|---|
| Discovery & inventory automation (scripts) | 1–2 engineer-weeks |
| Migration script development (discovery, firewall/service-endpoint changes, rollback, monitoring, policy deployment) | 2–3 engineer-weeks |
| Azure Policy definitions & initiative | 1 engineer-week |
| Monitoring (diagnostics, alerts, action groups) | 1 engineer-week |
| Pilot execution & validation | 1–2 engineer-weeks |
| Phased rollout execution (Dev → Non-Prod → Prod) | Ongoing, ~0.5–1 FTE across the program duration, scaling with batch cadence |
| Documentation, CAB submissions, communications | Ongoing, shared across the above |

## Go/No-Go Checklist

**Go/No-Go for Pilot start:**
- [ ] Architecture and design formally reviewed and approved (Architecture.md §3 trade-off explicitly acknowledged by Security/Compliance)
- [ ] Discovery inventory complete for the pilot scope
- [ ] Rollback procedure documented and understood by the executing team
- [ ] Monitoring/alerting deployable ahead of any Private Endpoint removal

**Go/No-Go for each subsequent phase (Dev → Non-Prod → Prod):**
- [ ] Prior phase's exit criteria fully met (`RolloutPlan.md`)
- [ ] No unresolved Sev1/Sev2 incidents attributable to the migration
- [ ] Policy compliance at the expected level for the completed phase
- [ ] CAB approval obtained for the next phase's batch(es)
- [ ] Communication sent to affected teams ahead of the change window

**Go/No-Go for Production phase specifically (additional gates):**
- [ ] Non-Production load/pattern validation showed no latency or reliability regression
- [ ] Exclusion list finalized and signed off by Security & Compliance
- [ ] Named on-call owner assigned for every Production batch's change window
- [ ] Executive sponsor briefed on residual risk (Architecture.md §3) and has explicitly accepted it
