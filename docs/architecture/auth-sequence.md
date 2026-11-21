# Customer Authentication and Service Operations Sequences

## Customer authentication via CPF

```mermaid
sequenceDiagram
    autonumber
    actor Customer as Customer
    participant APIM as API Management
    participant Auth as Auth Function
    participant OS as OS Service internal API

    Customer->>APIM: POST /api/auth/customer (CPF)
    APIM->>Auth: Forward CPF authentication request
    Auth->>OS: Validate CPF and request customer lookup with internal key
    OS-->>Auth: Customer ID and active status or not found
    Auth-->>APIM: Signed JWT with customer_id or RFC 7807 failure
    APIM-->>Customer: JWT or failure response
    Customer->>APIM: Request /api/v1/service-operations/... (Bearer JWT)
    APIM->>APIM: Validate issuer, audience, signature, and customer_id
    APIM->>APIM: Propagate validated customer identity
    APIM-->>Customer: API response
```

The gateway is the public policy boundary. The serverless Auth Function validates the customer's CPF and calls the OS Service internal API to look up the customer before issuing a short-lived JWT containing `customer_id`. APIM validates the token using the configured signing key and propagates the validated identity to the AKS API. Azure deployment requires a separate migration before this topology is released.

## Work order opening

```mermaid
sequenceDiagram
    autonumber
    actor Customer
    participant APIM as API Management
    participant OS as Service Operations
    participant DB as PostgreSQL service_operations
    participant Outbox as Transactional outbox
    participant Bus as Integration transport
    participant Catalog as Catalog Inventory
    participant Comm as Communication

    Customer->>APIM: POST /api/v1/service-operations/work-orders (Bearer token)
    APIM->>OS: Route request with validated customer identity
    OS->>DB: Validate references and persist WorkOrder
    OS->>Outbox: Persist WorkOrderOpened event in same transaction
    DB-->>OS: Commit
    OS-->>APIM: 201 Created (work order id and status)
    APIM-->>Customer: 201 Created
    Outbox->>Bus: Publish WorkOrderOpened asynchronously
    Bus->>Catalog: Reserve/check inventory as needed
    Bus->>Comm: Trigger customer communication as needed
```

Opening a work order is synchronous only through the Service Operations transaction. The API returns after the work order and its outbox message commit atomically. Downstream bounded contexts consume the integration event asynchronously, apply idempotent handling, and do not read or write the `service_operations` schema directly. A failed downstream action is retried or compensated by its own consumer rather than rolling back the committed operation.
