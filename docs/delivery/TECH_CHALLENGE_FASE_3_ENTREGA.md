# Tech Challenge — Fase 3 | Documento Consolidado de Entrega

> **Curso:** SOAT — Software Architecture Pós-Tech FIAP  
> **Projeto:** CatCar Platform  
> **Organização GitHub:** [RiseOn-CatCar](https://github.com/RiseOn-CatCar)  
> **Versão do documento:** 18 de setembro de 2026

---

## 1. Identificação do grupo

| Campo | Informação |
|---|---|
| **Nome do grupo** | RiseOn-CatCar |
| **Projeto** | CatCar Platform — Plataforma Integrada de Gestão de Oficina Mecânica |
| **Integrante** | Davi Holanda |
| **Turma / Curso** | SOAT — Software Architecture Pós-Tech FIAP |

> Antes do envio no Portal do Aluno, conferir se os dados de matrícula e eventuais demais integrantes estão completos na capa do PDF gerado a partir deste documento.

## 2. Repositórios entregues

A solução é composta por um meta-repositório e quatro repositórios independentes, todos na organização `RiseOn-CatCar`:

| Repositório | Responsabilidade |
|---|---|
| [catcar-platform](https://github.com/RiseOn-CatCar/catcar-platform) | Meta-repositório, documentação consolidada, automação local e composição dos submódulos. |
| [catcar-app](https://github.com/RiseOn-CatCar/catcar-app) | Monólito modular .NET 10, DDD, EF Core, Wolverine Outbox e Aspire AppHost. |
| [catcar-auth-function](https://github.com/RiseOn-CatCar/catcar-auth-function) | Azure Function serverless para autenticação de cliente por CPF e emissão de JWT. |
| [catcar-database-infra](https://github.com/RiseOn-CatCar/catcar-database-infra) | Terraform para PostgreSQL Flexible Server, Key Vault, DNS privado e segredos. |
| [catcar-kubernetes-infra](https://github.com/RiseOn-CatCar/catcar-kubernetes-infra) | Terraform para VNet, AKS, ACR, APIM, Azure Monitor, alertas e workbooks. |

## 3. Demonstração em vídeo (até 15 minutos)

- **URL do vídeo (YouTube ou Vimeo, público ou não listado):** `PENDENTE — inserir URL publicada antes da submissão.`
- **Duração máxima:** 15 minutos, conforme o enunciado.
- **Ambiente de demonstração:** Homologação (`develop`) ou ambiente local Aspire/Kind equivalente, identificando claramente o ambiente utilizado.

### Roteiro de apresentação — 15:00

| Tempo | Demonstração e narrativa |
|---:|---|
| 00:00–00:45 | Apresentar o grupo, o problema de gestão de oficina e a topologia dos cinco repositórios. Exibir o diagrama de componentes em nuvem. |
| 00:45–02:00 | Explicar o fluxo de borda: cliente → APIM → API no AKS ou Function de autenticação; apontar JWT, VNet e acesso privado aos dados. |
| 02:00–03:30 | Executar `POST /api/auth/customer` com CPF válido pela coleção Postman. Exibir validação, resposta JWT de cliente e o `X-Correlation-Id`. Mostrar brevemente a rejeição de CPF inválido. |
| 03:30–05:00 | Autenticar um Administrador/Técnico em `POST /api/v1/identity-access/auth/login`, demonstrando a separação entre token de cliente e token de backoffice. |
| 05:00–06:45 | Consumir APIs protegidas: cadastrar/consultar cliente e veículo, abrir e consultar uma ordem de serviço e chamar a métrica de tempo médio. Mostrar os headers Authorization e correlação no Postman. |
| 06:45–08:00 | Demonstrar catálogo/estoque e o fluxo de orçamento: serviço, item de inventário, criação/consulta e decisão de aprovação ou recusa. Explicar a comunicação assíncrona por Wolverine Outbox. |
| 08:00–09:15 | Abrir a documentação interativa: Swagger (`/swagger`), Scalar (`/docs`) e OpenAPI (`/openapi/v1.json`); importar a collection e o environment Postman versionados. |
| 09:15–11:00 | Exibir uma execução das pipelines CI/CD dos quatro repositórios: validação, testes/scans, build de imagem e etapas de infraestrutura/deploy. Destacar branches `develop` (Homologação) e `main` (Produção). |
| 11:00–12:15 | Mostrar o deploy automatizado: recursos Terraform no Azure e workload no AKS com HPA de 2 a 10 réplicas; apontar o APIM e o ACR com RBAC `AcrPull`. |
| 12:15–13:30 | Mostrar Azure Monitor/Application Insights: disponibilidade/health checks, latência, CPU, memória, alertas e workbook operacional. |
| 13:30–14:30 | Filtrar logs estruturados e traces distribuídos pelo mesmo `CorrelationId`, conectando a chamada Postman ao APIM, Function/API e banco. |
| 14:30–15:00 | Recapitular os requisitos atendidos, confirmar os links de evidência e informar onde se encontra este PDF/documento no repositório. |

## 4. Documentação e evidências técnicas

### Arquitetura, DDD e decisões

- [Diagrama de componentes e topologia em nuvem](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/architecture/cloud-components.md)
- [Diagramas de sequência — autenticação e ordem de serviço](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/architecture/auth-sequence.md)
- [Modelo Entidade-Relacionamento (ER)](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/architecture/er-model.md)
- [Artefatos DDD: visão geral](https://github.com/RiseOn-CatCar/catcar-platform/tree/main/docs/ddd)
- [Context Map](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/ddd/context-map.md), [Event Storming](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/ddd/event-storming.md), [estrutura de módulos](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/ddd/module-structure.md) e [glossário](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/ddd/glossary.md)

### RFCs e ADRs

- [RFC 001 — seleção do provedor de nuvem (Microsoft Azure)](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/architecture/rfc/001-cloud-provider-selection.md)
- [RFC 002 — banco gerenciado PostgreSQL 17](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/architecture/rfc/002-managed-database.md)
- [RFC 003 — autenticação serverless com Azure Functions](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/architecture/rfc/003-serverless-auth.md)
- [ADR 001 — comunicação assíncrona com Transactional Outbox](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/architecture/adr/001-asynchronous-communication-outbox.md)
- [ADR 002 — HPA e rate limiting no APIM](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/architecture/adr/002-hpa-and-apim-scaling.md)
- [ADR 003 — topologia de repositórios e composição Aspire](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/architecture/adr/003-repository-topology.md)

### Operação, segurança e APIs

- [Runbook de bootstrap Azure](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/azure-bootstrap.md)
- [Relatório de vulnerabilidades](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/vulnerability-report.md)
- [Relatório de auditoria e conformidade da Fase 3](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/fase-3-audit-report.md)
- [Swagger UI — `/swagger`](http://localhost:5000/swagger)
- [Scalar API Reference — `/docs`](http://localhost:5000/docs)
- [OpenAPI v3 JSON — `/openapi/v1.json`](http://localhost:5000/openapi/v1.json)
- [Collection Postman v2.1.0](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/postman/CatCar_Platform.postman_collection.json)
- [Environment template Postman](https://github.com/RiseOn-CatCar/catcar-platform/blob/main/docs/postman/CatCar_Platform.postman_environment.json)

## 5. Acesso do avaliador `soat-architecture`

**Confirmação registrada:** o controle de requisitos do projeto registra `soat-architecture` como colaborador com permissão de *push* nos quatro repositórios de entrega. A evidência rastreável está em [`catcar-app/docs/status-requisitos-entregaveis.md`](https://github.com/RiseOn-CatCar/catcar-app/blob/main/docs/status-requisitos-entregaveis.md), item `F3-ENT-06`.

| Repositório | Acesso a confirmar no GitHub | Evidência a anexar ao envio |
|---|---|---|
| [catcar-app](https://github.com/RiseOn-CatCar/catcar-app) | Colaborador `soat-architecture` com acesso ativo. | Captura de tela de **Settings → Collaborators and teams** ou aceite de convite. |
| [catcar-auth-function](https://github.com/RiseOn-CatCar/catcar-auth-function) | Colaborador `soat-architecture` com acesso ativo. | Captura de tela de **Settings → Collaborators and teams** ou aceite de convite. |
| [catcar-database-infra](https://github.com/RiseOn-CatCar/catcar-database-infra) | Colaborador `soat-architecture` com acesso ativo. | Captura de tela de **Settings → Collaborators and teams** ou aceite de convite. |
| [catcar-kubernetes-infra](https://github.com/RiseOn-CatCar/catcar-kubernetes-infra) | Colaborador `soat-architecture` com acesso ativo. | Captura de tela de **Settings → Collaborators and teams** ou aceite de convite. |

### Procedimento de comprovação antes da submissão

1. Um administrador da organização abre cada repositório e acessa **Settings → Collaborators and teams**.
2. Confirma que `soat-architecture` aparece como colaborador ativo — não apenas com convite pendente — com permissão mínima de leitura (o registro interno indica *push*).
3. Registra uma captura de tela por repositório, preservando o nome do repositório, o usuário e o status de acesso; não expõe tokens ou outros dados sensíveis.
4. Anexa as quatro evidências ao PDF final ou ao campo de observações do Portal do Aluno e mantém os repositórios acessíveis para a correção.

## 6. Resumo executivo de aderência aos requisitos obrigatórios

| Requisito obrigatório | Evidência de implementação |
|---|---|
| **API Gateway + autenticação serverless** | Azure API Management aplica política JWT e roteia `POST /api/auth/customer` para a Azure Function. A Function valida CPF, consulta cliente ativo e emite JWT HMAC-SHA256. |
| **Banco de dados gerenciado** | Azure Database for PostgreSQL Flexible Server 17 com subnet delegada, DNS privado, SSL e segredos protegidos no Azure Key Vault. |
| **Kubernetes escalável** | AKS multi-AZ com Azure CNI, Workload Identity e HPA baseado em CPU/memória, configurado de 2 a 10 réplicas. |
| **Infraestrutura como código** | Os stacks `catcar-database-infra` e `catcar-kubernetes-infra` descrevem a infraestrutura Azure obrigatória integralmente em Terraform, com pipelines próprias de validação e aplicação. |
| **Observabilidade e workbooks** | OpenTelemetry, Application Insights, Log Analytics, health checks, alertas de latência/CPU/memória/uptime e workbook operacional permitem acompanhamento técnico e de negócio. |
| **CI/CD dual-environment e governança** | Pipelines independentes publicam Homologação a partir de `develop` e Produção a partir de `main`; o bootstrap configura OIDC, ambientes e proteção de branches com PR, revisão e bloqueio de force-push/exclusão. |

## 7. Checklist final do Portal do Aluno

- [ ] Gerar o PDF deste documento: `./scripts/generate-delivery-pdf.sh`.
- [ ] Substituir a URL pendente pelo link público ou não listado do vídeo de até 15 minutos.
- [ ] Conferir identificação, integrantes e dados acadêmicos na capa do PDF.
- [ ] Verificar que os cinco links de repositórios e todos os links de documentação abrem corretamente.
- [ ] Anexar as quatro comprovações de acesso de `soat-architecture`.
- [ ] Enviar o PDF único e a URL do vídeo no Portal do Aluno.
