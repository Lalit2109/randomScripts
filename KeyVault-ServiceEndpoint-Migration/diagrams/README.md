# Diagrams

Mermaid source files, also embedded inline in the relevant docs. Kept here standalone so they can be rendered independently (e.g., in a wiki page, or via `mmdc`/Mermaid Live Editor) without extracting them from markdown.

| File | Also embedded in | Shows |
|---|---|---|
| `architecture-before.mmd` | `docs/Architecture.md` §1 | Current Private Endpoint-based architecture |
| `architecture-after.mmd` | `docs/Architecture.md` §2 | Proposed Service Endpoint-based architecture |
| `networking-flow.mmd` | `docs/Architecture.md` §4 | Request sequence and the dual-control (firewall + Entra ID) model |
| `per-vault-migration-state.mmd` | (new, standalone) | State machine for one Key Vault's migration, including rollback transitions |
| `rollout-phases.mmd` | `docs/RolloutPlan.md` | Phase 1-4 rollout sequencing with rollback arrows |
