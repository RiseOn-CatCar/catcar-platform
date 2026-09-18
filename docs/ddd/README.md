# DDD Documentation — CatCar Phase 1

This folder contains the Domain-Driven Design artifacts produced during the strategic design phase for CatCar's MVP.

## Purpose

These documents are the **Phase 1 DDD submission deliverables** referenced in `Fase_1_Tech_Challenge.md`. They establish the bounded context map, event storming diagrams, module structure, and ubiquitous language glossary used to align the team on the domain model before any production code was written.

## Artifacts

| File | Description |
|------|-------------|
| [event-storming.md](event-storming.md) + [.excalidraw](event-storming.excalidraw) | Event Storming diagrams — Work Order creation, tracking, and parts/supplies management flows |
| [context-map.md](context-map.md) + [.excalidraw](context-map.excalidraw) | Strategic Context Map — bounded contexts, integration relationships, and translation strategies |
| [module-structure.md](module-structure.md) + [.excalidraw](module-structure.excalidraw) | Module Structure diagram — .NET solution organization by Bounded Context |
| [glossary.md](glossary.md) | Ubiquitous Language glossary — ratified domain terms, definitions, and forbidden aliases |

## Bounded Contexts

| Context | Type | Description |
|---|---|---|
| `Atendimento/OS` | Core | Work order lifecycle, customer, vehicle, budget |
| `Catalogo & Estoque` | Supporting | Service catalog, parts/inventory, stock control |
| `Comunicacao com Cliente` | Supporting | External approval tokens, customer notifications |
| `Identidade & Acesso` | Generic | Administrative JWT authentication |

## Relationship to source

These files are mirrors of the design artifacts in `.kb/features/design-estrategico-fases-1-2/`. The `.excalidraw` files are editable in [Excalidraw](https://excalidraw.com); the `.md` files contain Mermaid diagrams for inline rendering in GitHub/GitLab.

## Design references

- Full strategic design rationale: [`.kb/features/design-estrategico-fases-1-2/design.md`](../../.kb/features/design-estrategico-fases-1-2/design.md)
- Context Map: [`.kb/features/design-estrategico-fases-1-2/context-map.md`](../../.kb/features/design-estrategico-fases-1-2/context-map.md)
- Module Structure: [`.kb/features/design-estrategico-fases-1-2/module-structure.md`](../../.kb/features/design-estrategico-fases-1-2/module-structure.md)