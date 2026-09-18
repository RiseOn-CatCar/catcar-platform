# RFC 003: Serverless Customer Authentication with Azure Function

- **Status:** Accepted
- **Date:** 2026-09-16
- **Decision owners:** CatCar architecture team

## Context

Customer authentication has bursty traffic and a sharply bounded responsibility: accept a CPF through the gateway, validate it against the customer record in PostgreSQL, and issue a signed JWT containing the customer's identity. It needs an independently deployable release cadence without coupling authentication to the AKS workload image.

## Decision

Deploy the `catcar-auth-function` as an Azure Function behind Azure API Management. The Function validates the customer's CPF by querying PostgreSQL and issues a short-lived JWT with `customer_id`, customer role, issuer, and audience claims. It obtains the signing configuration through managed identity and runtime secret storage. APIM validates the resulting token and propagates the validated customer identity to the versioned Service Operations API.

## Rationale

A Function scales from zero-to-burst demand and gives customer authentication its own deployment artifact and CI workflow. PostgreSQL remains the authoritative source for customer identity, while APIM remains the consistent external gateway for rate limiting, JWT validation, and identity propagation. Key Vault removes signing secrets from packages and GitHub secrets, and the separate function avoids exposing database credentials to a gateway policy.

## Consequences

- The Function CI builds, tests, publishes, and uploads a deployable artifact independently.
- CPF validation and customer lookup require least-privilege access to the customer PostgreSQL data.
- Cold-start behavior must be measured and the authentication endpoint must be covered by availability monitoring.
- Token lifetime, issuer, audience, and key rotation must be configuration-driven and coordinated between the Function, APIM, and API consumers.
- Service Operations endpoints consume the propagated `customer_id` claim to enforce customer ownership.

## Alternatives considered

- **Authentication inside the AKS API:** rejected because it couples release cadence and scaling to the main workload.
- **APIM policy-only authentication:** rejected because CPF validation, customer lookup, and signing-key lifecycle are application concerns, not gateway policy.
- **Third-party hosted identity provider:** deferred; it is viable when federation or customer identity requirements exceed the current customer-CPF scope.
