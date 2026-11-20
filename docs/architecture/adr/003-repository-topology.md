# ADR 003: Multi-Repository Topology and Aspire Submodule Composition

- **Status:** Accepted
- **Date:** 2026-09-18

> Historical decision: this ADR records the Phase 3 topology. The application repository has since become `catcar-os-service`; Phase 4 introduces separate Billing and Execution services and a platform-level AppHost. The [coordinated release process](../../release-process.md) retains the Phase 3 single-image AKS path.

## Context

The Phase 3 Tech Challenge specifications require splitting the CatCar system into four segregated, independently deployable Git repositories:
1. Serverless Authentication Function (`catcar-auth-function`)
2. Kubernetes & Observability Infrastructure (`catcar-kubernetes-infra`)
3. Managed Database & Secrets Infrastructure (`catcar-database-infra`)
4. Main Modular Monolith Application & Aspire AppHost (now `catcar-os-service`)

The Phase 3 Tech Challenge originally specified branch-based deployments to Homologation (`develop`) and Production (`main`). The current operating contract supersedes that model: component repositories run CI only; the `catcar-platform` repository pins their commits as submodules, and a strict `vMAJOR.MINOR.PATCH` tag on the platform repository triggers the coordinated release to the single Azure environment `rg-catcar`. The current local AppHost is `aspire/CatCar.AppHost/CatCar.AppHost.csproj` in the platform repository; Kind is local validation only.

## Decision

1. **Repository Segregation & History Preservation**:
   - The primary monorepo became the application repository, now `catcar-os-service`, preserving the core application history.
   - Dedicated repositories `catcar-auth-function`, `catcar-kubernetes-infra`, and `catcar-database-infra` were created by extracting relevant path histories using `git filter-repo`.

2. **Decoupled Infrastructure Pipelines**:
   - `catcar-kubernetes-infra` manages the foundational Azure VNet, AKS cluster, ACR, API Management (APIM), and Azure Monitor alert rules and workbooks.
   - `catcar-database-infra` provisions Azure Database for PostgreSQL Flexible Server, Azure Key Vault, and private endpoints. It dynamically resolves the private endpoint subnet (`snet-private-endpoints`) via Terraform `data "azurerm_subnet"` lookup, eliminating tight cross-stack output variable bindings.

3. **Aspire Dual-Mode Orchestration via Pinned Git Submodule**:
   - In Phase 3, the authentication repository was linked into the application repository under `external/catcar-auth-function` as a pinned submodule; the application AppHost registered the function by project path in run mode and modelled the API workload in publish mode.
   - The current platform-level AppHost composes the OS, Billing and Execution services and authentication function for local development.

4. **Coordinated Single-Environment Release**:
   - The four component repositories run CI only. The `catcar-platform` repository pins each component commit as a Git submodule.
   - Only a strict `vMAJOR.MINOR.PATCH` tag on `catcar-platform` triggers `release.yml` through GitHub Environment `azure`, deploying those pinned commits to the single Azure environment `rg-catcar` in order: foundation infrastructure → database → API on AKS → Function → alerts and smoke checks.
   - Kind is for local validation only and is never release evidence.

## Consequences

- **Coordinated Life Cycle**: Components retain separate histories and CI, while the platform repository coordinates their pinned commits into a gated Azure release.
- **Inner Loop Integrity**: Local development remains unified with zero extra setup overhead; developers clone with `--recurse-submodules` and run Aspire normally.
- **Loose Coupling**: Cross-repo references are limited to published language contracts (`IIntegrationEvent`), standard HTTP/JWT protocols, and runtime environment configuration.

## Alternatives Considered

- **Package-based ServiceDefaults (NuGet)**: Rejected because duplicating the lightweight `CatCar.ServiceDefaults` across repositories avoids premature packaging overhead and internal feed maintenance.
- **Monorepo with Path Filtering**: Rejected as non-compliant with the explicit Phase 3 architectural requirement demanding four segregated GitHub repositories.
- **Direct HTTP Mocking for Local Function**: Rejected because local Aspire execution with real isolated worker runtime provides higher fidelity for end-to-end integration testing.
