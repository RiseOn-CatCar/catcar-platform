# RFC 002: Managed PostgreSQL Database

- **Status:** Accepted
- **Date:** 2026-09-16
- **Decision owners:** CatCar architecture team

## Context

CatCar requires transactional persistence, indexes and uniqueness guarantees, EF Core compatibility, backup retention, private networking, and a clear operational ownership boundary. The domain already uses PostgreSQL-specific `xmin` optimistic concurrency tokens.

## Decision

Use Azure Database for PostgreSQL Flexible Server, PostgreSQL 17, with private networking. The server is deployed into a delegated subnet, resolved through a private DNS zone, and has public network access disabled. Connection strings are stored in Azure Key Vault rather than configuration files.

## Rationale

Flexible Server preserves PostgreSQL semantics used by EF Core while moving patching, backups, and server availability management to Azure. It supports private VNet integration and a managed service tier suitable for production workloads. One logical database hosts four schema-per-DbContext boundaries: `service_operations`, `catalog_inventory`, `communication`, and `identity_access`.

## Consequences

- No application workload connects through a public database endpoint.
- The database infrastructure state owns the delegated subnet, private DNS zone, server, database, Key Vault secret, and any explicitly allowed firewall rules.
- Schema ownership is enforced in application code; cross-context integrity uses integration events, not cross-schema foreign keys.
- The team must plan the Flexible Server SKU, storage, zone, and backup-retention settings per environment.

## Alternatives considered

- **Azure SQL Database:** rejected because PostgreSQL behavior and the existing `xmin` concurrency strategy are intentional design dependencies.
- **PostgreSQL in AKS:** rejected because it adds storage, backup, failover, and patching responsibility without a workload-driven need.
- **Public Flexible Server endpoint:** rejected because it widens the attack surface and undermines the VNet design.
