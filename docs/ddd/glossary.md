# DDD Glossary — Ubiquitous Language

**Ratified:** true (see [design.md](../../.kb/features/design-estrategico-fases-1-2/design.md#ddd-glossary))

This glossary defines the domain terms that cross bounded context boundaries. Each term has a formal definition and a list of aliases that must not be used, to prevent conceptual leakage between contexts.

---

## WorkOrder *(in `Atendimento/OS`)*

- **Definition:** unit of tracking for work performed on a specific vehicle, with status history, active budget, and operational result.
- **Aliases (forbidden):** "chamado", "ticket".

---

## Budget *(in `Atendimento/OS`)*

- **Definition:** active commercial proposal of services and parts linked to a WorkOrder, frozen for audit from the moment of issuance.
- **Aliases (forbidden):** "cotação dinâmica".

---

## ApprovalLink / ExternalAccessToken *(in `Comunicacao com Cliente`)*

- **Definition:** secure external mechanism by which the customer approves or rejects the budget without needing an administrative login. Single-use token, linked to a specific budget, with expiration.
- **Aliases (forbidden):** "login do cliente", "sessão do cliente".

---

## InventoryItem *(in `Catalogo & Estoque`)*

- **Definition:** part or supply controlled with availability, reservation, and consumption traceable by WorkOrder.
- **Aliases (forbidden):** "produto" when the intent is operational inventory.

---

## CatalogedService *(in `Catalogo & Estoque`)*

- **Definition:** service offered by the shop, with description, base price, and category. Does not represent execution — execution is the WorkOrder's responsibility.
- **Aliases (forbidden):** "item de serviço", "serviço executado".

---

## AdministrativeUser *(in `Identidade & Acesso`)*

- **Definition:** administrative panel access credential, with an associated role.
- **Aliases (forbidden):** "cliente" (customers don't have logins), "funcionário" (role model, not identity).

---

## Customer *(in `Atendimento/OS`)*

- **Definition:** individual or legal entity that contracts services for a vehicle, identified by CPF/CNPJ.
- **Aliases (forbidden):** "usuário" (confuses with administrative), "consumidor" (retail language).

---

## Vehicle *(in `Atendimento/OS`)*

- **Definition:** a customer's vehicle, identified by license plate, with make/model/year.
- **Aliases (forbidden):** "carro" (when context is technical), "automóvel" (same reason).

---

## Source

Extracted from [design.md](../../.kb/features/design-estrategico-fases-1-2/design.md#ddd-glossary) §DDD Glossary.  
Ratified: 2026-06-09.