# Contratos entre microsserviços — Fase 4

Este documento é a fonte única dos contratos entre `catcar-os-service`, `catcar-billing-service` e `catcar-execution-service`. Cada serviço mantém a **própria cópia** dos tipos de mensagem que publica ou consome. Não há biblioteca de contratos compartilhada. A compatibilidade é garantida por três coisas:

- a identidade estável da mensagem (`[MessageIdentity]` do Wolverine);
- os nomes e tipos dos campos abaixo, serializados em JSON com System.Text.Json;
- testes de contrato que serializam um exemplo e comparam os nomes dos campos.

## 1. Regras gerais

| Regra | Valor |
|---|---|
| Broker | RabbitMQ (`WolverineFx.RabbitMQ`), recurso Aspire/K8s `messaging`, connection string `ConnectionStrings:messaging` (URI `amqp://`) |
| Roteamento | `UseRabbitMq(...).AutoProvision().UseConventionalRouting()`: uma exchange por identidade de mensagem e uma fila por serviço consumidor |
| Durabilidade | `UseDurableInboxOnAllListeners()` e `UseDurableOutboxOnAllSendingEndpoints()`; o OS e o Execution usam o outbox do EF Core no PostgreSQL, o Billing usa Marten com `IntegrateWithWolverine()` |
| Identidade | `[MessageIdentity("catcar.<produtor>.<nome-kebab>.v1")]` em toda mensagem cruzada |
| Correlação | Toda mensagem tem `WorkOrderId` (Guid, id da Saga) e `CorrelationId` (Guid) |
| Datas | `DateTime` UTC |
| Dinheiro | `decimal`, BRL |
| Idempotência | Todo consumidor tolera reentrega: repetir a mensagem não muda o resultado nem publica efeitos duplicados |
| Compensações | Comandos fire-and-forget e idempotentes, sem resposta |

## 2. Mensagens

### 2.1 `os-service` → `billing-service` (comandos)

| Identidade | Tipo | Campos |
|---|---|---|
| `catcar.os.request-budget.v1` | `RequestBudget` | `WorkOrderId`, `CustomerId`, `CustomerName` (string), `CustomerEmail` (string), `Lines` (lista de `BudgetLineRequest`), `RequestedAt`, `CorrelationId` |
| `catcar.os.cancel-budget.v1` | `CancelBudget` | `WorkOrderId`, `BudgetId`, `Reason` (string), `CorrelationId` |
| `catcar.os.request-payment.v1` | `RequestPayment` | `WorkOrderId`, `BudgetId`, `Amount` (decimal), `CustomerEmail`, `CorrelationId` |
| `catcar.os.refund-payment.v1` | `RefundPayment` | `WorkOrderId`, `BudgetId`, `Reason`, `CorrelationId` |

`BudgetLineRequest`: `Type` (`"Service"` ou `"Part"`), `ReferenceId` (Guid do serviço de catálogo ou da peça), `Description`, `UnitPrice`, `Quantity` (int > 0).

### 2.2 `billing-service` → `os-service` (eventos)

| Identidade | Tipo | Campos |
|---|---|---|
| `catcar.billing.budget-issued.v1` | `BudgetIssued` | `WorkOrderId`, `BudgetId`, `TotalAmount`, `IssuedAt`, `CorrelationId` |
| `catcar.billing.budget-approved.v1` | `BudgetApproved` | `WorkOrderId`, `BudgetId`, `TotalAmount`, `ApprovedAt`, `CorrelationId` |
| `catcar.billing.budget-rejected.v1` | `BudgetRejected` | `WorkOrderId`, `BudgetId`, `Reason`, `RejectedAt`, `CorrelationId` |
| `catcar.billing.payment-confirmed.v1` | `PaymentConfirmed` | `WorkOrderId`, `BudgetId`, `PaymentId` (string, id externo), `Amount`, `ConfirmedAt`, `CorrelationId` |
| `catcar.billing.payment-failed.v1` | `PaymentFailed` | `WorkOrderId`, `BudgetId`, `Reason`, `FailedAt`, `CorrelationId` |

### 2.3 `os-service` → `execution-service` (comandos)

| Identidade | Tipo | Campos |
|---|---|---|
| `catcar.os.reserve-parts.v1` | `ReserveParts` | `WorkOrderId`, `Parts` (lista de `PartQuantity`), `CorrelationId` |
| `catcar.os.release-parts.v1` | `ReleaseParts` | `WorkOrderId`, `Reason`, `CorrelationId` |
| `catcar.os.start-execution.v1` | `StartExecution` | `WorkOrderId`, `Services` (lista de `ServiceQuantity`), `Parts` (lista de `PartQuantity`), `CorrelationId` |

`PartQuantity`: `InventoryItemId`, `Quantity`. `ServiceQuantity`: `CatalogedServiceId`, `Description`, `Quantity`.

`ReserveParts` com lista vazia é válido e responde `PartsReserved`.

### 2.4 `execution-service` → `os-service` (eventos)

| Identidade | Tipo | Campos |
|---|---|---|
| `catcar.execution.parts-reserved.v1` | `PartsReserved` | `WorkOrderId`, `ReservedAt`, `CorrelationId` |
| `catcar.execution.parts-reservation-failed.v1` | `PartsReservationFailed` | `WorkOrderId`, `FailureCode` (string), `FailedAt`, `CorrelationId` |
| `catcar.execution.execution-completed.v1` | `ExecutionCompleted` | `WorkOrderId`, `CompletedAt`, `CorrelationId` |
| `catcar.execution.execution-failed.v1` | `ExecutionFailed` | `WorkOrderId`, `Reason`, `FailedAt`, `CorrelationId` |

### 2.5 `os-service` → todos (evento de domínio publicado)

| Identidade | Tipo | Campos |
|---|---|---|
| `catcar.os.work-order-status-changed.v1` | `WorkOrderStatusChanged` | `WorkOrderId`, `CustomerId`, `CustomerName`, `CustomerEmail` (string?), `PreviousStatus`, `NewStatus`, `ChangedAt`, `CorrelationId`, `EventId` |

O `billing-service` consome esse evento para os e-mails de status, no lugar do antigo `WorkOrderStatusChangedNotificationHandler`. O dado do cliente vem no próprio evento, então não há consulta ao banco da OS.

## 3. REST síncrono (somente leitura, interno ao cluster)

| Chamador | Endpoint | Resposta |
|---|---|---|
| `os-service` | `GET {Services:Execution}/internal/v1/catalog/services/{id}` | `200 {id, description, unitPrice, isActive}` ou `404` |
| `os-service` | `GET {Services:Execution}/internal/v1/catalog/parts/{id}` | `200 {id, description, unitPrice, isActive, quantityInStock}` ou `404` |

- As rotas `/internal/*` não têm autenticação e nunca são publicadas no APIM.
- O cliente HTTP usa service discovery do Aspire: `Services:Execution` = `https+http://execution-service`. No Kubernetes é `http://execution-service:8080`.
- Os endpoints administrativos de todos os serviços validam o mesmo JWT administrativo emitido pelo `os-service`, com a mesma configuração `Jwt:*`.

## 4. `WorkOrderSaga` (orquestrada, no `os-service`)

- Classe `WorkOrderSaga : Wolverine.Saga` com `Id = WorkOrderId`, persistida pelo EF Core no `ServiceOperationsDbContext`.
- Começa quando o administrador pede o orçamento: `POST .../work-orders/{id}/budget` responde `202 Accepted`.
- Termina com `MarkCompleted()` em todo estado final. Um novo pedido de orçamento abre uma nova Saga com o mesmo id.
- Timeouts via `TimeoutMessage`: `Saga:ApprovalTimeout` (padrão 72h) e `Saga:PaymentTimeout` (padrão 24h).
- Todo handler de mensagem de outro passo implementa `NotFound` como no-op com log.

| Mensagem recebida | Pré-condição na Saga | Ação na OS | Mensagens enviadas | Estado da OS |
|---|---|---|---|---|
| (início) pedido de orçamento | OS `InDiagnosis` com ≥1 linha | — | `RequestBudget`, `ApprovalTimeout` agendado | `InDiagnosis` |
| `BudgetIssued` | aguardando orçamento | `MarkBudgetIssued(budgetId)` | — | `AwaitingApproval` |
| `BudgetRejected` | aguardando aprovação | `RecordApproval(false)` | — (fim) | `InDiagnosis` |
| `ApprovalTimeout` | aguardando aprovação | `Cancel` | `CancelBudget` (fim) | `Cancelled` |
| `BudgetApproved` | aguardando aprovação | `RecordApproval(true)` | `ReserveParts` | `AwaitingApproval` |
| `PartsReservationFailed` | aguardando reserva | `RecordInventoryReservationFailure` | `CancelBudget` (fim) | `InDiagnosis` |
| `PartsReserved` | aguardando reserva | `AwaitPayment` | `RequestPayment`, `PaymentTimeout` agendado | `AwaitingPayment` |
| `PaymentFailed` ou `PaymentTimeout` | aguardando pagamento | `Cancel` | `ReleaseParts`, `CancelBudget` (fim) | `Cancelled` |
| `PaymentConfirmed` | aguardando pagamento | `StartExecution` | `StartExecution` | `InExecution` |
| `ExecutionFailed` | em execução | `Cancel` | `RefundPayment`, `ReleaseParts` (fim) | `Cancelled` |
| `ExecutionCompleted` | em execução | `Complete` | — (fim) | `Completed` |

- A entrega (`Delivered`) continua sendo um comando administrativo da OS, fora da Saga.
- Novos estados em `WorkOrderStatus`: `AwaitingPayment` e `Cancelled`.
- Toda transição publica `WorkOrderStatusChanged`.

## 5. Layout, nomes e configuração

| Item | os-service | billing-service | execution-service |
|---|---|---|---|
| API (caminho no repositório) | `src/Api/CatCar.Api.csproj` | `src/Api/CatCar.Billing.Api.csproj` | `src/Api/CatCar.Execution.Api.csproj` |
| Solução | `CatCar.slnx` | `CatCar.Billing.slnx` | `CatCar.Execution.slnx` |
| Recurso Aspire/K8s | `os-service` | `billing-service` | `execution-service` |
| Connection string do banco | `catcar` (banco `catcar_os`) | `billing` (banco `catcar_billing`, Marten) | `execution` (banco `catcar_execution`) |
| Prefixo HTTP público | `/api/v1/service-operations`, `/api/v1/identity-access` | `/api/v1/billing` (orçamentos, links de aprovação, pagamentos, webhook) | `/api/v1/catalog-inventory`, `/api/v1/execution` |
| Imagem | `catcar-os-service` | `catcar-billing-service` | `catcar-execution-service` |
| Projeto SonarCloud (org `riseon`) | `riseon_catcar-os-service` | `riseon_catcar-billing-service` | `riseon_catcar-execution-service` |

Comum aos três serviços:

- Alvo `net11.0` e SDK do `global.json` (11.0.100); Central Package Management; `TreatWarningsAsErrors`; `AnalysisMode=All`.
- `SharedKernel` e `ServiceDefaults` copiados do `catcar-os-service`.
- Health checks em `/health/live` e `/health/ready`. Porta 8080 no container, que roda como não-root.
- Migração por `--migrate` (EF Core) ou criação do schema na subida (Marten).

O AppHost do Aspire para desenvolvimento local fica no `catcar-platform` (`aspire/CatCar.AppHost`) e referencia as três APIs pelo caminho do submódulo. Os serviços não têm AppHost próprio.

## 6. CI de cada serviço (`.github/workflows/ci.yml`)

1. `build-test`: restore, `dotnet format whitespace --verify-no-changes`, build Release, testes com coverlet (OpenCover). Falha se a cobertura de linhas do código do serviço ficar abaixo de 80% (excluídos migrations, `Program` e código gerado). O relatório sai como artefato.
2. `sonar`: `dotnet-sonarscanner` com `SONAR_TOKEN`, organização `riseon` e quality gate em modo wait. É pulado quando o secret não existe.
3. `security`: Opengrep e `dotnet list package --vulnerable`; Trivy na imagem (falha em CRITICAL/HIGH).
4. `deploy-kind`: em PR e push na `main`, cria kind no runner (`helm/kind-action`), faz build e `kind load` da imagem, `kubectl apply -k k8s/overlays/ci` (serviço + PostgreSQL + RabbitMQ efêmeros), espera o rollout, roda a migração e um smoke em `/health/ready` e num endpoint público.

Manifestos: `k8s/base` (Deployment, Service, ConfigMap, HPA, Job de migração, referência ao Secret `<serviço>-secrets`) e `k8s/overlays/ci` (base + dependências efêmeras + Secret de teste).
