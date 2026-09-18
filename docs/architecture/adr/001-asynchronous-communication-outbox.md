# ADR 001: Asynchronous Cross-Context Communication with a Transactional Outbox

- **Status:** Accepted
- **Date:** 2026-09-16

## Context

Bounded contexts must not reference each other's code or databases. Work-order, budget, inventory, and communication actions nevertheless require reliable propagation of business facts. A direct publish after a database commit can lose an event; publishing before the commit can publish an event for a transaction that rolls back.

## Decision

Each producing context persists its integration event in a transactional outbox within the same transaction as its aggregate mutation. A background dispatcher publishes the serialized event to the integration transport. Consumers are idempotent and record their own processing state. Cross-context requests use published contracts and local snapshots only.

## Consequences

- Aggregate state and the corresponding integration event commit atomically.
- Delivery is at-least-once; duplicate-safe consumers and event identifiers are required.
- Eventual consistency is explicit. The command response reflects the producer's committed state, not downstream completion.
- Failed processing is retried and, when business semantics require it, compensated by a subsequent event rather than a distributed transaction.

## Alternatives considered

- **Synchronous direct calls:** rejected because they create temporal coupling and cascading availability failures.
- **Cross-schema joins/foreign keys:** rejected because they violate bounded-context data ownership.
- **Distributed two-phase commit:** rejected because it adds operational complexity and weakens availability without solving external side effects.
