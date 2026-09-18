# Entity-Relationship Model

Each bounded context owns one EF Core `DbContext` and one PostgreSQL schema. Names below use the physical snake_case names produced by the naming convention. Audit fields (`created_at`, `updated_at`, `created_by`, `updated_by`) and PostgreSQL `xmin` concurrency token are present on aggregate tables unless stated otherwise.

```mermaid
erDiagram
    service_operations_customers ||--o{ service_operations_vehicles : owns
    service_operations_customers ||--o{ service_operations_work_orders : opens
    service_operations_vehicles ||--o{ service_operations_work_orders : assigned_to
    service_operations_work_orders ||--o{ service_operations_work_order_requested_services : contains
    service_operations_work_orders ||--o{ service_operations_work_order_requested_parts : contains
    service_operations_work_orders ||--o{ service_operations_budgets : has
    service_operations_budgets ||--o{ service_operations_budget_lines : contains

    catalog_inventory_inventory_items ||--o{ catalog_inventory_inventory_reservations : reserved

    service_operations_customers {
      uuid id PK
      string document_number UK
      string document_type
      string name
      string phone
      string email
      boolean is_active
    }
    service_operations_vehicles {
      uuid id PK
      uuid customer_id "logical FK"
      string plate UK
      string brand
      string model
      int manufacture_year
      boolean is_active
    }
    service_operations_work_orders {
      uuid id PK
      uuid customer_id "logical FK"
      uuid vehicle_id "logical FK"
      uuid active_budget_id "logical FK"
      string initial_description
      string status
      datetime opened_at
      datetime diagnosis_started_at
      datetime budget_approved_at
      datetime completed_at
      datetime delivered_at
      datetime last_updated_at
    }
    service_operations_work_order_requested_services {
      uuid id PK
      uuid work_order_id FK
      uuid cataloged_service_id "external reference"
      string description
      decimal unit_price
      int quantity
    }
    service_operations_work_order_requested_parts {
      uuid id PK
      uuid work_order_id FK
      uuid inventory_item_id "external reference"
      string description
      decimal unit_price
      int quantity
    }
    service_operations_budgets {
      uuid id PK
      uuid work_order_id "logical FK"
      string status
      datetime issued_at
      string rejection_reason
    }
    service_operations_budget_lines {
      uuid id PK
      uuid budget_id FK
      string type
      uuid reference_id "external reference"
      string description
      decimal unit_price
      int quantity
    }
    catalog_inventory_cataloged_services {
      uuid id PK
      string name UK
      string description
      int estimated_duration_minutes
      decimal price_amount
      string price_currency
      boolean is_active
    }
    catalog_inventory_inventory_items {
      uuid id PK
      string sku UK
      string name
      string description
      decimal unit_price_amount
      string unit_price_currency
      int quantity_in_stock
      int minimum_stock_threshold
      boolean is_active
    }
    catalog_inventory_inventory_reservations {
      uuid id PK
      uuid work_order_id "external reference"
      uuid budget_id "external reference"
      uuid inventory_item_id "logical FK"
      int quantity
      string status
      datetime reserved_at
      datetime consumed_at
      datetime released_at
    }
    communication_external_access_tokens {
      uuid id PK
      uuid budget_id "external reference"
      string token_hash UK
      string status
      datetime issued_at
      datetime expires_at
      datetime consumed_at
    }
    identity_access_administrative_users {
      uuid id PK
      string email UK
      string name
      string password_hash
      string role
      boolean is_active
    }
```

## Schema ownership and constraints

| Schema | Tables | Key constraints and relationships |
|---|---|---|
| `service_operations` | `customers`, `vehicles`, `work_orders`, `work_order_requested_services`, `work_order_requested_parts`, `budgets`, `budget_lines` | `customers.document_number`, `vehicles.plate` are unique. `vehicles.customer_id`, `work_orders.customer_id`, `work_orders.vehicle_id`, and `budgets.work_order_id` express relations within the context. The owned line-item tables have physical FKs to their aggregate owner. |
| `catalog_inventory` | `cataloged_services`, `inventory_items`, `inventory_reservations` | `cataloged_services.name` and `inventory_items.sku` are unique. A reservation has a unique composite `(budget_id, inventory_item_id)` and references the local inventory item. |
| `communication` | `external_access_tokens` | `token_hash` is unique. `budget_id` is an external identity received from Service Operations, not a cross-schema FK. |
| `identity_access` | `administrative_users` | `email` is unique. Role is stored as a string-backed domain enum. |

## Cross-context relationship rule

The diagram distinguishes a physical/local FK from an external or logical reference. `cataloged_service_id`, `inventory_item_id`, `work_order_id`, and `budget_id` that cross a schema boundary are identifiers only. Their correctness is established through integration contracts and local snapshots, never through cross-schema foreign keys or direct database access.
