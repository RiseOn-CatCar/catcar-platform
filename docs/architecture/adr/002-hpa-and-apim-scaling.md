# ADR 002: HPA Workload Scaling and APIM Rate Limiting

- **Status:** Accepted
- **Date:** 2026-09-16

## Context

Traffic can spike during workshop operating hours, while downstream dependencies have finite capacity. Static pod counts either overprovision normal operation or fail under bursts. An unrestricted gateway lets a single consumer exhaust the cluster or database connection budget.

## Decision

Use Kubernetes Horizontal Pod Autoscalers for CatCar workloads, with resource requests/limits defining the scaling signal and safe pod bounds. Use APIM rate-limit and quota policies at the public gateway, segmented by authenticated caller or subscription. Alert when cluster CPU/memory approaches saturation, average request latency exceeds two seconds, or an uptime probe fails.

## Consequences

- AKS node-pool autoscaling and workload HPA address different layers: HPA changes pod count; cluster autoscaler supplies nodes for scheduled pods.
- Every horizontally scaled workload must be stateless or externalize state, be ready for concurrent processing, and use idempotent event consumers.
- APIM returns an explicit throttling response before the backend is overloaded; clients must honor retry guidance.
- Capacity thresholds, HPA bounds, and APIM limits are environment configuration reviewed alongside load-test evidence.

## Alternatives considered

- **Fixed replicas:** rejected because it cannot economically handle variable demand.
- **Gateway-only scaling protection:** rejected because it cannot react to internal consumer or background workload pressure.
- **Unlimited gateway traffic:** rejected because it turns dependent-service saturation into a platform-wide outage.
