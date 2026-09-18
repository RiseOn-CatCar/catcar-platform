# RFC 001: Azure Cloud Provider Selection

- **Status:** Accepted
- **Date:** 2026-09-16
- **Decision owners:** CatCar architecture team

## Context

CatCar needs managed Kubernetes hosting, a serverless authentication boundary, managed PostgreSQL, image storage, an API gateway, secrets management, and unified telemetry. The platform must support independent infrastructure repositories and least-privilege deployment identities.

## Decision

Use Microsoft Azure as the production cloud provider: AKS for container orchestration, Azure Functions for serverless authentication, API Management for the gateway, Azure Database for PostgreSQL Flexible Server for relational persistence, ACR for images, Key Vault for secrets, and Azure Monitor/Application Insights for observability.

## Rationale

Azure provides first-party integration among AKS workload identity, ACR pull permissions, Key Vault RBAC, Application Insights, Log Analytics, and APIM. This minimizes custom credential plumbing and gives the deployment pipelines a consistent OIDC authentication model. The service mapping also directly covers the required runtime components without operating Kubernetes control planes, database replication, or telemetry ingestion ourselves.

## Consequences

- Infrastructure uses the `azurerm` provider and Azure resource IDs as the stable contract between the Kubernetes, database, and alert states.
- Azure region and SKU choices are explicit Terraform variables, so cost and availability decisions remain deploy-time concerns.
- The architecture accepts Azure service limits, region availability constraints, and vendor-specific operational knowledge.
- Terraform states remain separated by ownership; the database state must not mutate AKS, APIM, or ACR.

## Alternatives considered

- **AWS:** functionally viable, but would require a different IAM, gateway, registry, and telemetry integration model.
- **Google Cloud:** functionally viable, but does not improve the required service integration enough to justify another operational stack.
- **Self-managed Kubernetes and PostgreSQL:** rejected because it shifts patching, backups, HA, and observability operations onto the team.
