# ADR 003: Multi-Repository Topology and Aspire Submodule Composition

- **Status:** Accepted
- **Date:** 2026-09-18

## Context

The Phase 3 Tech Challenge specifications require splitting the CatCar system into four segregated, independently deployable Git repositories:
1. Serverless Authentication Function (`catcar-auth-function`)
2. Kubernetes & Observability Infrastructure (`catcar-kubernetes-infra`)
3. Managed Database & Secrets Infrastructure (`catcar-database-infra`)
4. Main Modular Monolith Application & Aspire AppHost (`catcar-app`)

Each repository must have an autonomous CI/CD pipeline targeting both **Homologation** (branch `develop`) and **Production** (branch `main`). At the same time, local developer experience (inner loop) must continue to run the complete solution—API, PostgreSQL database, Azurite storage emulator, and Serverless Auth Function—using .NET Aspire with a single command (`dotnet run --project src/Host/CatCar.AppHost`).

## Decision

1. **Repository Segregation & History Preservation**:
   - The primary monorepo was renamed to `catcar-app`, preserving full Git commit history for core application domain slices, tests, and Aspire configuration.
   - Dedicated repositories `catcar-auth-function`, `catcar-kubernetes-infra`, and `catcar-database-infra` were created by extracting relevant path histories using `git filter-repo`.

2. **Decoupled Infrastructure Pipelines**:
   - `catcar-kubernetes-infra` manages the foundational Azure VNet, AKS cluster, ACR, API Management (APIM), and Azure Monitor alert rules and workbooks.
   - `catcar-database-infra` provisions Azure Database for PostgreSQL Flexible Server, Azure Key Vault, and private endpoints. It dynamically resolves the private endpoint subnet (`snet-private-endpoints`) via Terraform `data "azurerm_subnet"` lookup, eliminating tight cross-stack output variable bindings.

3. **Aspire Dual-Mode Orchestration via Pinned Git Submodule**:
   - The `catcar-auth-function` repository is linked into `catcar-app` under `external/catcar-auth-function` as a pinned Git submodule.
   - In **Run Mode** (`isRunMode`), Aspire AppHost registers the function via the path overload:
     `builder.AddAzureFunctionsProject("auth-function", "../../../external/catcar-auth-function/src/CatCar.AuthFunction/CatCar.AuthFunction.csproj")`.
     This provides unified local debugging without MSBuild `<ProjectReference>` compilation coupling or SDK type generation.
   - In **Publish Mode** (`isPublishMode`), Aspire models only the Kubernetes API container workloads and external connection strings, while Azure Container Apps deployment for the Auth Function is managed strictly by its own CI/CD pipeline.

4. **Branching & Environments**:
   - Protected branches `main` (Production environment) and `develop` (Homologation environment) are enforced across all four repositories with required pull request reviews and status checks.

## Consequences

- **Independent Life Cycles**: Infrastructure, serverless authentication, and application services deploy independently without cascading deployment dependencies.
- **Inner Loop Integrity**: Local development remains unified with zero extra setup overhead; developers clone with `--recurse-submodules` and run Aspire normally.
- **Loose Coupling**: Cross-repo references are limited to published language contracts (`IIntegrationEvent`), standard HTTP/JWT protocols, and runtime environment configuration.

## Alternatives Considered

- **Package-based ServiceDefaults (NuGet)**: Rejected because duplicating the lightweight `CatCar.ServiceDefaults` across repositories avoids premature packaging overhead and internal feed maintenance.
- **Monorepo with Path Filtering**: Rejected as non-compliant with the explicit Phase 3 architectural requirement demanding four segregated GitHub repositories.
- **Direct HTTP Mocking for Local Function**: Rejected because local Aspire execution with real isolated worker runtime provides higher fidelity for end-to-end integration testing.
