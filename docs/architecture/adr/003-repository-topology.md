# ADR 003: Multi-Repository Topology, Academic Cloud Consolidation, and Aspire Submodule Composition

- **Status:** Accepted (Updated for Academic Cloud Consolidation)
- **Date:** 2026-09-18 (Updated 2026-09-20)

## Context

The CatCar platform is organized into four segregated, independently deployable Git repositories coordinated by `catcar-platform`:
1. Serverless Authentication Function (`catcar-auth-function`)
2. Kubernetes & Observability Infrastructure (`catcar-kubernetes-infra`)
3. Managed Database & Secrets Infrastructure (`catcar-database-infra`)
4. Main Modular Monolith Application & Aspire AppHost (`catcar-app`)

Under the **Academic Cloud Consolidation Model**, CatCar replaces duplicated long-lived Azure environments with a single Production environment (`catcar-prod`) and utilizes the existing .NET Aspire AppHost as the standard pre-production (homologation) environment (`make dev`). The cloud target must stretch a total USD 100 Azure student credit while preserving Phase 3 functionality (APIM, serverless CPF authentication, managed PostgreSQL, AKS/HPA, resource requests/limits, monitoring, and automated deployment).

## Decision

1. **Trunk-Based Development & Production Tag Release**:
   - Protected branch `main` is the single source of truth across all five repositories.
   - Production deployment is triggered exclusively by stable SemVer release tags (`v*.*.*`) whose commits are reachable from `main`.
   - The `develop` branch and duplicated homologation cloud topology are decommissioned. Local Aspire is the primary homologation path (`make dev`).

2. **Decoupled Infrastructure & Multi-Repo Release Order**:
   - `catcar-kubernetes-infra` provisions the VNet (`vnet-catcar-prod`), AKS cluster (`aks-catcar-prod`, Free SKU, Standard_B2s 1–2 nodes), ACR (`catcarprod<suffix>`, Basic SKU), APIM (`apim-catcar-prod-<suffix>`, Consumption SKU), and Azure Monitor alert rules.
   - `catcar-database-infra` provisions Azure Database for PostgreSQL Flexible Server 17 (`psql-catcar-prod`, B1ms, private VNet) and Key Vault (`kv-catcar-prod-<suffix>`, Standard, public endpoint enabled for OIDC runners).
   - `catcar-auth-function` provisions its Flex Consumption Function App (`func-catcar-prod-<suffix>`, FC1, 512 MiB, VNet integrated) via dedicated `infra/` Terraform.
   - Deployment sequence: Kubernetes Infra -> Database Infra -> Auth Function -> API Workload.

3. **Aspire Local Composition & Ingress Gateway Key Boundary**:
   - Local inner loop runs the full topology (`api`, `postgres`, `auth-storage`, `auth-function`) using .NET Aspire AppHost (`dotnet run --project src/Host/CatCar.AppHost`).
   - In Production, APIM injects `X-CatCar-Gateway-Key` on all backend requests. Origin workloads (API and Auth Function) reject POST requests missing or carrying an invalid key with HTTP 403 Forbidden. Health probes (`/health/live`, `/health/ready`) are exempt.

4. **Cold-by-Default Operations**:
   - Compute workloads (AKS and PostgreSQL) are automatically stopped nightly at 02:00 UTC via `.github/workflows/cloud-runtime.yml` to preserve student credit, and started on demand via `workflow_dispatch` or deployment workflows.

5. **Public / Private Endpoint Trade-Offs**:
   - PostgreSQL remains private via VNet subnet delegation (`snet-postgresql`) and private DNS (`private.postgres.database.azure.com`).
   - ACR, Key Vault, and API Ingress use public service endpoints + Entra ID OIDC / RBAC / Gateway Key authentication because student budget constraints reject Premium/private-endpoint SKUs.

## Consequences

- **Cost Efficiency**: Total cloud spend easily fits within the USD 100 student credit without sacrificing architecture, security, or observability.
- **Trunk-Based Velocity**: Developers merge to `main` via PRs and release production via tagged commits without managing dual cloud environments.
- **High Inner Loop Fidelity**: Aspire orchestrates local PostgreSQL, API, and Auth Function with zero cloud dependencies.
