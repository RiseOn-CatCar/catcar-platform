# Auditoria de conformidade — Tech Challenge, fases 1, 2 e 3

**Data de referência:** 16/11/2026.  
**Escopo:** árvore de trabalho do meta-repositório e seus quatro sub-repositórios; verificações locais e consultas somente leitura ao GitHub.  
**Referências normativas:** [Fase 1](requirements/Fase_1_Tech_Challenge.md), [Fase 2](requirements/Fase_2_Tech_Challenge.md) e [Fase 3](requirements/Fase_3_Tech_Challenge.md).  
**Relatório histórico confrontado:** [auditoria anterior da fase 3](fase-3-audit-report.md).

## 1. Parecer executivo

**Não há evidência suficiente para declarar as três fases integralmente atendidas. Recomenda-se fechar os bloqueios desta auditoria antes da extração de microsserviços da fase 4.**

| Fase | Parecer | Fundamentação |
|---|---|---|
| 1 — aplicação e domínio | Parcialmente atendida | A maior parte dos fluxos está implementada e os testes selecionados passaram. Permanecem risco de inconsistência entre aprovação e estoque, entrega de e-mails não demonstrada, ressalvas de cobertura e entregáveis acadêmicos incompletos. |
| 2 — evolução e operação | Parcialmente atendida | Há arquitetura modular, regras de listagem, Docker/Compose, IaC e publicação Kubernetes por Aspire. A publicação atual falhou no build por vulnerabilidades dos pacotes Aspire; deploy integrado e escalabilidade em execução não foram comprovados. |
| 3 — cloud, segurança e observabilidade | Parcialmente atendida | APIM, autenticação serverless, infraestrutura e observabilidade possuem código. Há falhas de OIDC nos runs examinados, configurações cloud divergentes, lacuna no provisionamento/configuração da Function e falta de correspondência demonstrada entre telemetria emitida e dashboards. |

**Resultados objetivos:** 324 testes selecionados passaram; os três roots Terraform foram validados; o acesso de `soat-architecture` foi confirmado nos quatro repositórios. Em contrapartida, a tentativa atual de `aspire publish` terminou com código 6, bloqueada por `NU1904`/`NU1903` no AppHost.

O relatório anterior está parcialmente superado: os gaps de roles/verbos do APIM, métrica de finalização, correlação na API e autorização de abertura da OS foram corrigidos no código atual. Isso não comprova que essas correções estejam implantadas.

## 2. Método e limites

A auditoria foi dividida em quatro frentes: funcionalidades/segurança; evolução/CI/Kubernetes; cloud/serverless/observabilidade; documentação/entregáveis. A consolidação confrontou as conclusões entre frentes para eliminar falsos positivos.

### Classificação das evidências

- **I — Implementado:** código ou artefato localizado e compatível com o requisito; não significa execução integrada aprovada.
- **P — Parcial:** implementação incompleta, cadeia operacional não fechada ou ressalva material identificada.
- **N — Não atendido:** contradição diretamente observada com o requisito.
- **NC — Não comprovado:** evidência necessária não está disponível; não significa que o recurso inexista fora dos repositórios.
- **C — Confirmado:** verificação executada nesta sessão, no escopo explicitado.

As referências `caminho:linha` são relativas à raiz do meta-repositório. A árvore local e os commits de runs remotos **não são presumidos idênticos**. Os runs citados são de setembro de 2026, consultados nesta auditoria; não constituem comprovação do estado atual do Azure.

Não houve alteração do produto, apply Terraform, deploy, mudança de permissões ou implementação da fase 4. Não foram executados novos scans SAST/Trivy/SonarQube; as vulnerabilidades atuais registradas abaixo foram reportadas pelo restore NuGet da tentativa de publicação.

**Limites operacionais:** Docker e alternativas não estavam disponíveis; integração PostgreSQL/Testcontainers e E2E não foram executados localmente. Azure CLI não estava disponível e não houve consulta direta ao estado dos recursos Azure. Consultas GitHub foram autenticadas e somente leitura.

## 3. Verificações executadas

### 3.1 Testes locais

SDK utilizado: `.NET 10.0.401`, via `mise exec dotnet@10.0.401 -- dotnet`.

Cada projeto abaixo foi executado uma vez, em Release, com filtro `FullyQualifiedName!~Integration`, coleta `XPlat Code Coverage` e logger TRX. O projeto E2E ficou fora dessa seleção.

| Projeto em `catcar-app/tests/`, salvo indicação | Aprovados | Falhas |
|---|---:|---:|
| `SharedKernel.Tests/CatCar.SharedKernel.Tests.csproj` | 12 | 0 |
| `Contexts/ServiceOperations.Tests/CatCar.Contexts.ServiceOperations.Tests.csproj` | 126 | 0 |
| `Contexts/CatalogInventory.Tests/CatCar.Contexts.CatalogInventory.Tests.csproj` | 77 | 0 |
| `Contexts/Communication.Tests/CatCar.Contexts.Communication.Tests.csproj` | 41 | 0 |
| `Contexts/IdentityAccess.Tests/CatCar.Contexts.IdentityAccess.Tests.csproj` | 35 | 0 |
| `Architecture.Tests/CatCar.Architecture.Tests.csproj` | 20 | 0 |
| `catcar-auth-function/tests/CatCar.AuthFunction.Tests/CatCar.AuthFunction.Tests.csproj` | 13 | 0 |
| **Total selecionado** | **324** | **0** |

Forma do comando, aplicada aos caminhos acima:

```bash
mise exec dotnet@10.0.401 -- dotnet test <projeto.csproj> -c Release \
  --filter 'FullyQualifiedName!~Integration' \
  --collect:'XPlat Code Coverage' \
  --results-directory <diretorio-temporario-do-projeto> \
  --logger 'trx;LogFileName=audit.trx' --verbosity minimal
```

TRX e relatórios Cobertura foram produzidos em `/tmp/catcar-audit-tests.eeKdgw/`. Esse caminho é evidência temporária da sessão, não artefato versionado nem link público de entrega.

### 3.2 Cobertura de linhas observada

Método: agregar os sete relatórios por **caminho absoluto da fonte + número da linha**, normalizando o elemento `sources` do Cobertura, usando o maior número de hits para não duplicar linhas compartilhadas. Nos contextos, selecionar fontes em `/Domain/`; no SharedKernel, selecionar a biblioteca inteira. Não é média dos percentuais dos projetos, cobertura de branches ou cobertura da suíte completa.

| Escopo | Linhas cobertas | Linhas instrumentadas | Cobertura |
|---|---:|---:|---:|
| ServiceOperations — Domain | 300 | 335 | 89,55% |
| CatalogInventory — Domain | 165 | 187 | 88,24% |
| Communication — Domain | 50 | 50 | 100,00% |
| IdentityAccess — Domain | 42 | 53 | 79,25% |
| SharedKernel | 32 | 44 | 72,73% |

Os dois domínios centrais de negócio superam 80% na seleção executada. O SharedKernel não atinge a meta interna de 80% declarada nas regras do projeto; IdentityAccess também fica abaixo caso seja incluído no escopo crítico. Isso não permite afirmar o percentual final da suíte completa. O CI coleta e publica cobertura, mas não foi identificado gate de 80% por domínio em `catcar-app/.github/workflows/ci.yml:62-79` e `catcar-app/tests/Directory.Build.props:9-11`.

### 3.3 Terraform

Foram copiadas as configurações para `/tmp/catcar-audit-terraform.zgrMPo/`, sem modificar os roots originais. Em cada root foi executado `terraform init -backend=false -input=false` seguido de `terraform validate`, usando Terraform 1.17.1.

| Root | Resultado |
|---|---|
| `catcar-database-infra` | Configuração válida |
| `catcar-kubernetes-infra` | Configuração válida |
| `catcar-kubernetes-infra/alerts` | Configuração válida |

O provider selecionado foi `hashicorp/azurerm 4.81.0`. A validação **não** resolve a existência dos recursos referenciados, comprova acesso privado, avalia credenciais nem substitui `plan`/`apply` no ambiente alvo.

### 3.4 Publicação Kubernetes/Aspire — falha atual observada

Após restaurar as ferramentas locais, foi tentada a mesma modalidade de publicação Production usada pelo workflow, a partir de `catcar-app/src/Host`:

```bash
mise exec dotnet@10.0.401 -- dotnet tool run aspire -- publish \
  --non-interactive --environment Production \
  -o /tmp/catcar-audit-aspire-publish
```

Foram fornecidos parâmetros de geração para resource group, registry, workspace, App Insights, imagem, chaves e conexão, com valores exclusivos de auditoria, sem uso de credenciais reais ou intenção de deploy.

**Resultado: falha, código 6, antes da geração verificável dos charts.** O build do AppHost foi bloqueado por warnings NuGet tratados como erros:

| Pacote reportado | Versão | Diagnóstico | Advisory |
|---|---|---|---|
| `Aspire.Dashboard.Sdk.linux-x64` | 13.5.4 | `NU1904` — crítica | [GHSA-4g86-54fm-h9h8](https://github.com/advisories/GHSA-4g86-54fm-h9h8) |
| `Aspire.Hosting` | 13.5.4 | `NU1903` — alta | [GHSA-f7vh-h5g3-7jrh](https://github.com/advisories/GHSA-f7vh-h5g3-7jrh) |
| `Aspire.Hosting.AppHost` | 13.5.4 | `NU1903` — alta | [GHSA-f7vh-h5g3-7jrh](https://github.com/advisories/GHSA-f7vh-h5g3-7jrh) |

Âncoras: `catcar-app/src/Host/CatCar.AppHost/CatCar.AppHost.csproj:1`, `catcar-app/Directory.Packages.props:11-20`, `catcar-app/Directory.Build.props:6`.

Não houve supressão dos avisos ou nova tentativa contornando o bloqueio. Os 324 testes aprovados não contradizem esse resultado: a seleção não exigiu construir/publicar o AppHost.

## 4. Matriz — fase 1

### 4.1 Fluxos funcionais, segurança e qualidade

Nas matrizes e nos achados, `SO` abrevia `catcar-app/src/Contexts/ServiceOperations`, `CI` abrevia `catcar-app/src/Contexts/CatalogInventory` e `Communication` abrevia `catcar-app/src/Contexts/Communication`.

| ID | Requisito | Status | Evidência e ressalva |
|---|---|---|---|
| F1-F01 | Identificar cliente por CPF/CNPJ | I | `SO/Domain/ValueObjects/DocumentNumber.cs:38-98`; cadastro verifica documento duplicado em `SO/Features/Customers/RegisterCustomer/RegisterCustomerHandler.cs:20-33`. |
| F1-F02 | Veículo com placa, marca, modelo e ano | I | `SO/Features/Vehicles/RegisterVehicle/RegisterVehicleHandler.cs:16-41`; validator `:8-26`; `SO/Domain/ValueObjects/LicensePlate.cs:27-51`. |
| F1-F03 | Vincular OS ao cliente e veículo corretos | I | `SO/Features/WorkOrders/OpenWorkOrder/OpenWorkOrderHandler.cs:67-89` rejeita vínculo entre titulares diferentes. |
| F1-F04 | Incluir serviços | I | `SO/Integrations/CatalogInventoryAcl.cs:12-26`; `SO/Features/WorkOrders/AddRequestedService/AddRequestedServiceHandler.cs:16-43`; snapshots de preço/descrição. |
| F1-F05 | Incluir peças/insumos | I | `SO/Features/WorkOrders/AddRequestedPart/AddRequestedPartHandler.cs:16-47`; consulta disponibilidade, sem reservar nessa etapa. |
| F1-F06 | Gerar orçamento automaticamente a partir dos itens | I | Abertura com itens em `OpenWorkOrderHandler.cs:94-117,134-160`; emissão posterior em `SO/Features/WorkOrders/IssueBudget/IssueBudgetHandler.cs:35-69` calcula orçamento dos snapshots, sem exigir preço manual. |
| F1-F07 | Enviar orçamento ao cliente | P | `catcar-app/src/Contexts/Communication/Features/ApprovalLinks/SendApprovalRequest/SendApprovalRequestHandler.cs:19-66`; sem e-mail ou snapshot, registra aviso e não envia; entrega externa não demonstrada. |
| F1-F08 | Aprovação/recusa pelo cliente | I | `Communication/Features/ApprovalLinks/DecideApproval/DecideApprovalHandler.cs:22-55` e `SO/Features/WorkOrders/RecordBudgetDecision/RecordBudgetDecisionHandler.cs:34-68`; token com expiração/uso único. |
| F1-F09 | Seis estados obrigatórios | I | `SO/Domain/WorkOrders/WorkOrderStatus.cs:6-14`: Received, InDiagnosis, AwaitingApproval, InExecution, Completed, Delivered. |
| F1-F10 | Alterar estados conforme ações | I | `SO/Domain/WorkOrders/WorkOrder.cs:78-181`; ações de diagnóstico, emissão, decisão, conclusão e entrega. Ressalva de estoque em A05. |
| F1-F11 | Cliente consultar progresso da própria OS | I | `SO/Features/WorkOrders/GetWorkOrderProgress/GetWorkOrderProgressEndpoint.cs:12-25` e handler `:8-21`; identidade emitida pela Function, não pelo login administrativo. Integração HTTP/cloud não comprovada. |
| F1-F12 | CRUD clientes | I | `SO/EndpointRouteBuilderExtensions.cs:41-48`; atualização, consulta/lista e ativação/desativação. Exclusão lógica. |
| F1-F13 | CRUD veículos | I | `SO/EndpointRouteBuilderExtensions.cs:49-56`; consulta/lista, atualização e ativação/desativação. |
| F1-F14 | CRUD serviços | I | `CI/EndpointRouteBuilderExtensions.cs:30-36`; cadastro, consulta, atualização e ativação/desativação. |
| F1-F15 | CRUD peças/insumos e estoque | P | `CI/EndpointRouteBuilderExtensions.cs:38-46`; `CI/Domain/InventoryItems/InventoryItem.cs:56-68,120-137`. Operações existem; falha de reserva pode deixar OS avançada, conforme A05. |
| F1-F16 | Listagem/detalhamento da OS | I | `SO/EndpointRouteBuilderExtensions.cs:62-63`; `SO/Infrastructure/Persistence/WorkOrderRepository.cs:21-43`. |
| F1-F17 | Tempo médio de execução | I | `SO/Infrastructure/Persistence/WorkOrderRepository.cs:45-65`; inclui finalização. Há teste PostgreSQL em `catcar-app/tests/Contexts/ServiceOperations.Tests/Integration/WorkOrderRepositoryIntegrationTests.cs:12-52`, não executado nesta seleção. |
| F1-F18 | JWT administrativo | I | `catcar-app/src/Contexts/IdentityAccess/Infrastructure/Security/JwtTokenGenerator.cs:19-43`; validação em `Infrastructure/DependencyInjection.cs:27-39`; autorização nos endpoints. |
| F1-F19 | Validar CPF/CNPJ e placa | I | Value objects citados em F1-F01/F02; testes selecionados passaram. Isso não equivale a teste HTTP de todas as políticas. |
| F1-F20 | Testes unitários e integração dos fluxos principais | P | Unitários selecionados aprovados; integração/outbox/repositório existe, mas não foi executada localmente. E2E existente cobre principalmente wiring/health, não todo o ciclo comercial. |
| F1-T01 | Back-end monolítico | I | `catcar-app/src/Api/Program.cs:141-151` compõe os quatro contextos na mesma API. A Function de autenticação da fase 3 não extrai os módulos de negócio. |
| F1-T02 | Banco com justificativa | I | PostgreSQL e justificativa em `docs/architecture/rfc/002-managed-database.md:7-30`. |
| F1-T03 | REST documentado por Swagger ou similar | I | Minimal APIs, `AddOpenApi` e Scalar em `catcar-app/src/Api/Program.cs:48,118-130`; documentação HTTP exposta em Development. O edital não exige torná-la pública em produção. |
| F1-T04 | Dockerfile e Compose completos para desenvolvimento | I | `catcar-app/Dockerfile:1-51`; `catcar-app/docker-compose.yml:1-32`. Não executados sem Docker. Não substituem a topologia cloud da fase 3. |
| F1-T05 | Cobertura mínima de 80% nos domínios críticos | P | SO/CI acima de 80% medidos; escopo da meta precisa ser explícito. SharedKernel abaixo da meta interna; não há gate por domínio. Ver seção 3.2. |
| F1-T06 | Execução local documentada | I | `README.md:240-364`; `catcar-app/README.md:51-148,202-221`. Caminho Aspire está atualmente bloqueado pelo build da seção 3.4. |
| F1-T07 | Repositório privado com acesso ao avaliador | P/N | Acesso confirmado; os quatro repositórios estão públicos. O requisito literal de privacidade da fase 1 não é atendido no estado atual; isso não prova como foram entregues historicamente. |

**Interpretação adotada:** “orçamento automático” significa calcular preços/totais a partir dos itens, sem digitação manual do orçamento. Não foi tratado como obrigação de emitir um novo orçamento a cada alteração de linha. Aprovação/recusa e reserva/consumo são examinados como continuidade dos fluxos e controle de estoque, sem impor antecipadamente Saga Pattern da fase 4.

## 5. Matriz — fase 2

| ID | Requisito | Status | Evidência e ressalva |
|---|---|---|---|
| F2-F01 | Abertura com cliente, veículo, serviços e peças; devolver ID | I | `SO/Features/WorkOrders/OpenWorkOrder/OpenWorkOrderCommand.cs:4-11`, endpoint `:16-67` e handler `:32-164`; retorna 201 com WorkOrderId. Cliente/veículo são referências cadastradas previamente. |
| F2-F02 | Consultar situação nos seis estados | I | Endpoint/handler de progresso citados em F1-F11; enum citado em F1-F09. |
| F2-F03 | Notificação externa de aprovação ou recusa | I | `catcar-app/src/Contexts/Communication/Features/ApprovalLinks/DecideApproval/DecideApprovalEndpoint.cs:13-38`; decisão pública autenticada pelo token do link. |
| F2-F04 | Ordenar Em execução > Aguardando aprovação > Diagnóstico > Recebida | I | `SO/Infrastructure/Persistence/WorkOrderRepository.cs:20-42` usa prioridade e ordenação correspondentes. |
| F2-F05 | Mais antigas primeiro | I | Ordenação secundária `OpenedAt` ascendente no mesmo repositório. Verificação efetiva SQL depende do teste de integração não executado. |
| F2-F06 | Excluir finalizadas/entregues da listagem operacional | I | Filtro padrão do repositório; `SO/Features/WorkOrders/ListWorkOrders/ListWorkOrdersEndpoint.cs:16-18`, `includeClosed=false`. Consulta explícita de histórico não invalida esse padrão. |
| F2-F07 | Atualização/comunicação de status por ferramenta como e-mail | P | `Communication/Features/StatusNotifications/WorkOrderStatusChangedNotificationHandler.cs:15-51,68-121`; sender em `Communication/Notifications/AzureCommunicationEmailSender.cs:65-98`. Envio real não comprovado. |
| F2-T01 | Clean Code e Clean/Hexagonal Architecture | I | Contextos, Domain/Features/Infrastructure e ACLs; 20 testes de arquitetura passaram. Mesma assembly por contexto não é, isoladamente, violação da separação de dependências. Não equivale a certificação arquitetural exaustiva. |
| F2-T02 | Testes dos fluxos críticos | P | Testes de abertura, orçamento, decisão, listagem, notificação e persistência existem; execução parcial descrita na seção 3. |
| F2-T03 | Dockerfile e Compose revisados | I | Arquivos citados em F1-T04; build de imagem/local runtime não executado nesta sessão. |
| F2-T04 | Deployment, Service, ConfigMap e Secret Kubernetes | P | Publicação gerada pelo AppHost em `catcar-app/src/Host/CatCar.AppHost/AppHost.cs:64-147`; customização em `KubernetesPublishingExtensions.cs:12-95`; migração em `catcar-app/k8s/migration-job.yaml:1-54`. Geração atual bloqueada no restore. |
| F2-T05 | HPA com CPU e memória | P | `KubernetesPublishingExtensions.cs:61-95,111-187` define autoscaling/v2, CPU/memória 70%, 2–10 réplicas. Não foi possível verificar o YAML gerado ou a escala em cluster. |
| F2-T06 | Terraform para cluster e banco | I | Roots dedicados validados nesta sessão. Conectividade/provisionamento real não comprovado; contratos de ambiente divergentes em A03. |
| F2-T07 | CI: build, testes e imagem | P | `catcar-app/.github/workflows/ci.yml:14-79,202-275`; há runs históricos com jobs aprovados, mas a publicação atual está bloqueada e não há certificação da suíte completa atual. |
| F2-T08 | CD: deploy cluster, banco e manifestos | P | Workflow `:358-630` autentica, publica imagem, aplica Job de migração, executa deploy e aguarda rollout. Provisionamento do banco é pipeline Terraform separado. Runs examinados não comprovam deploy bem-sucedido. |

**Topologia:** não se considera a ausência de `/infra` dentro de `catcar-app` uma falha automática: a fase 3 exige separar infra em outros repositórios. Manifestos gerados por Aspire podem satisfazer a intenção funcional, mas o enunciado da fase 2 menciona YAMLs em `/k8s`; é necessário apresentar os artefatos gerados na entrega, não apenas a existência do gerador. Hoje essa geração não foi concluída.

## 6. Matriz — fase 3

| ID | Requisito | Status | Evidência e ressalva |
|---|---|---|---|
| F3-T01 | API Gateway e roteamento | I | `catcar-kubernetes-infra/main.tf:243-464`; `apim-policy.xml:1-91`. Rotas de auth e API e verbos necessários definidos; reachability não testada. |
| F3-T02 | Function validar CPF | I | `catcar-auth-function/src/CatCar.AuthFunction/AuthenticateCustomerFunction.cs:22-92,473-510`; testes serverless aprovados. Aceitar também CNPJ não viola a exigência de CPF. |
| F3-T03 | Consultar existência e status do cliente | I | `AuthenticateCustomerFunction.cs:62-92`; `CustomerLookupService.cs:9-32` consulta cliente e atividade. Banco real não exercitado. |
| F3-T04 | Emitir JWT válido para APIs protegidas | I | `AuthenticateCustomerFunction.cs:423-469`; issuer/audience, expiração, role Customer e customer_id; 13 testes serverless passaram. Chave compartilhada nos ambientes não comprovada. |
| F3-T05 | Proteger rotas sensíveis e isolar clientes | I | `catcar-kubernetes-infra/apim-policy.xml:34-87`; API aplica policies e titularidade. Política atual aceita colaboradores nas rotas administrativas; não foi testada contra APIM implantado. |
| F3-T06 | Quatro repositórios separados | C | `.gitmodules:1-12` e consulta GitHub confirmam app, auth-function, database-infra e kubernetes-infra. |
| F3-T07 | CI/CD independente com deploy cloud | P | Workflows existem nos quatro; os runs e falhas da seção 7 impedem declarar a cadeia funcional comprovada. |
| F3-T08 | Main protegida, sem commits diretos, PR obrigatório | P | Proteção clássica confirmada; bypass explícito para daviholandas. Não há rulesets adicionais nem checks obrigatórios. Ver seção 7. |
| F3-T09 | Deploy automático de homologação e produção | P | Mapeamento develop/homologation e main/production nos workflows; deploys dos runs examinados falharam ou foram ignorados. PR ignorar deploy é esperado, mas não prova CD de push. |
| F3-T10 | Function serverless operacional e provisionada | P | Código e imagem existem; workflow atualiza Container App preexistente. Não foi localizada criação/configuração cloud correspondente no Terraform, AppHost de publicação ou bootstrap. Ver A04. |
| F3-T11 | Banco gerenciado | I | `catcar-database-infra/main.tf:51-100` PostgreSQL Flexible Server 17, DNS privado e rede; código validado, apply não comprovado. |
| F3-T12 | Kubernetes escalável | I | `catcar-kubernetes-infra/main.tf:185-237` e variáveis de node pool/autoscaler. HPA de workload tem ressalva F2-T05. Sem teste de carga/escala. |
| F3-T13 | Terraform para provisionamento | P | Rede, AKS, APIM, banco, Key Vault, monitoramento/workbook codificados; cadeia de provisionamento da Function não fechada. |
| F3-O01 | Integração de observabilidade | P | `catcar-app/src/Host/CatCar.ServiceDefaults/Extensions.cs:35-104`; Azure Monitor condicionado à configuração. Não foi comprovada ingestão no ambiente. |
| F3-O02 | Latência APIs | P | `catcar-kubernetes-infra/alerts/catcar-alerts.tf:137-157`, alerta >2s. Recurso, dados e disparo não observados no Azure. |
| F3-O03 | CPU/memória Kubernetes | P | `alerts/catcar-alerts.tf:93-135`, limiares 80%/85%; apply dos alertas condicionado a IDs de recursos. |
| F3-O04 | Healthchecks/uptime | P | API `/health/live` e `/health/ready` em `Program.cs:153-155`; teste sintético e alerta em `alerts/catcar-alerts.tf:159-202`. Disponibilidade externa não medida. |
| F3-O05 | Alertar falha no processamento de OS | P | Query em `alerts/catcar-alerts.tf:64-91` procura WorkOrder com severidade >=3. Compatibilidade com falhas efetivamente emitidas e disparo não demonstrados. |
| F3-O06 | Logs JSON e correlação | P | `catcar-app/src/Api/Program.cs:20-23,92-115` JSON e X-Correlation-Id/LogContext. Correlação ponta a ponta com Function/gateway e ingestão não demonstradas. |
| F3-O07 | Dashboard de volume diário de OS | P | Workbook provisionado em `main.tf:178-186`; query `workbooks/catcar-dashboard.json:17` deduplica por operation_Id/id/itemId, não pela identidade de domínio da OS. |
| F3-O08 | Tempo por Diagnóstico/Execução/Finalização | P | Backend tem `AverageFinalizationTimeHours`; query `workbooks/catcar-dashboard.json:39` requer Status/TargetStatus e DurationHours/Duration sem produtor de domínio correspondente localizado. |
| F3-O09 | Dashboard de erros de integração | P | Query em `workbooks/catcar-dashboard.json:55`; dependência de logs, categoria/severidade e ingestão ainda não validada. |

## 7. Evidências GitHub e contratos de ambiente

### 7.1 Governança e acesso

As consultas `repos/{org}/{repo}`, `branches`, `branches/{branch}/protection`, `rulesets?includes_parents=true`, `environments` e `collaborators/soat-architecture/permission` confirmaram:

- Quatro repositórios **públicos**, com `main` e `develop` existentes/protegidas.
- `soat-architecture` com permissão **write nos quatro**. A pendência histórica de acesso não se confirma.
- Environments `homologation` e `production` existentes, sem regras de proteção de environment na resposta consultada. Aprovação manual de deployment não é exigência das fases 1–3.
- Uma aprovação de PR exigida em todas as `main`; `develop` também exige uma, exceto kubernetes-infra, que exige zero.
- Force-push e exclusão bloqueados; `enforce_admins=true`.
- Bypass de PR explicitamente autorizado para `daviholandas`; `required_status_checks=null`; nenhum ruleset adicional retornado.

A proteção existe, mas não sustenta a afirmação absoluta de que ninguém pode contornar PR. Checks obrigatórios são uma melhoria de enforcement relevante; sua ausência não é apresentada como requisito textual autônomo da fase 3, diferentemente do PR obrigatório.

Repositórios: [app](https://github.com/RiseOn-CatCar/catcar-app), [Function](https://github.com/RiseOn-CatCar/catcar-auth-function), [banco](https://github.com/RiseOn-CatCar/catcar-database-infra), [Kubernetes](https://github.com/RiseOn-CatCar/catcar-kubernetes-infra).

### 7.2 Runs examinados

A consulta selecionou o último run retornado para cada branch, que pode ser um evento `pull_request`, não necessariamente o último push/deploy. A amostra não é inventário de todas as execuções históricas.

| Repositório/branch | Run | Resultado observado |
|---|---|---|
| app/main | [35412719447](https://github.com/RiseOn-CatCar/catcar-app/actions/runs/35412719447) | Push, success global; ambos os jobs de deploy skipped. |
| app/develop | [35412368180](https://github.com/RiseOn-CatCar/catcar-app/actions/runs/35412368180) | PR, jobs de deploy skipped. |
| auth/main | [35412634873](https://github.com/RiseOn-CatCar/catcar-auth-function/actions/runs/35412634873) | Falha em Azure Login do docker-build; deploys skipped. |
| auth/develop | [35412498406](https://github.com/RiseOn-CatCar/catcar-auth-function/actions/runs/35412498406) | PR, build/test success; imagem/deploy skipped. |
| banco/main | [35412746449](https://github.com/RiseOn-CatCar/catcar-database-infra/actions/runs/35412746449) | Falha em Azure Login do apply de produção. |
| banco/develop | [35412485269](https://github.com/RiseOn-CatCar/catcar-database-infra/actions/runs/35412485269) | PR, validação success; applies skipped. |
| Kubernetes/main | [35412552820](https://github.com/RiseOn-CatCar/catcar-kubernetes-infra/actions/runs/35412552820) | Falha em Azure Login do apply de produção. |
| Kubernetes/develop | [35412463955](https://github.com/RiseOn-CatCar/catcar-kubernetes-infra/actions/runs/35412463955) | PR, validações success; applies skipped. |
| app/feature, run mais recente examinado | [35632296673](https://github.com/RiseOn-CatCar/catcar-app/actions/runs/35632296673) | Oito E2E falharam porque o projeto auth-function não foi localizado; cleanup teve NullReferenceException secundária. |

Nos três runs de produção que falharam em login, os logs registram **AADSTS700213**, sem federated identity correspondente ao subject apresentado, no formato `repo:RiseOn-CatCar@330941078/<repositorio>@<id>:environment:production`. A correção deve confrontar subject, issuer e audience efetivos; não basta afirmar que OIDC está definido no YAML.

**Ressalva E2E:** o log remoto procura `external/...` e o caminho irmão. A fonte atual já contém checkout em `catcar-app/.github/workflows/ci.yml:39-43` e resolução nested/irmão em `AppHost.cs:23-30`. Portanto, a falha histórica não prova que o mesmo defeito persista na árvore atual. É necessário um run completo atualizado; não foi proposta uma segunda correção sem reproduzir o estado atual.

### 7.3 Configuração remota versus IaC

Foram consultadas somente variáveis não secretas de nomes de recursos, em nível de repositório e dos dois environments.

| Configuração | Valor observado | Consequência estática |
|---|---|---|
| `CATCAR_FOUNDATION_RESOURCE_GROUP` no repositório, nos quatro repos | `catcar-homolog` | É herdado onde não há override de environment. |
| Override de produção no app | `CatCar` | App aponta ao foundation RG CatCar. |
| Override de produção em auth/banco/Kubernetes | Ausente para essa variável | Banco/Kubernetes herdam catcar-homolog apesar de TF_VAR_environment=prod. |
| Homologação, `ACR_NAME` | `crccarhomolog` | Não corresponde ao nome derivado de application_name+environment no Terraform padrão (`catcarhomolog`). |
| Homologação, `CATCAR_LOG_ANALYTICS_WORKSPACE_NAME` | `log-catcar-homolog` | Terraform declara `law-catcar-homolog`. |

Âncoras: `catcar-app/.github/workflows/ci.yml:390-396,525-533`; `catcar-database-infra/.github/workflows/ci-cd.yml:73-77`; `catcar-kubernetes-infra/.github/workflows/ci-cd.yml:112-127`; `catcar-kubernetes-infra/main.tf:22,160`; `catcar-database-infra/main.tf:14-23`.

Além das variáveis remotas, os defaults isolados dos roots divergem: cluster usa RG `CatCar`, banco `catcar-prod`, e o banco busca a VNet dentro de seu próprio RG de entrada. **[INFERENCE]** Aplicar os stacks sem alinhar entradas/recursos existentes pode falhar na busca da VNet, login de registry ou referência ao workspace. Os runs analisados falharam antes, no OIDC; não se atribui essas falhas históricas à divergência de nomes.

## 8. Documentação e entregáveis

| ID | Requisito | Status | Evidência e pendência |
|---|---|---|---|
| D1-01 | Event Storming de criação/acompanhamento OS | I | `docs/ddd/event-storming.md:10-343`. |
| D1-02 | Event Storming de peças/insumos | I | Mesmo documento `:345-535`. |
| D1-03 | Linguagem ubíqua e diagramas DDD | I | `docs/ddd/glossary.md:1-65`, `context-map.md:8-75`, `docs/ddd/README.md:7-29`; Mermaid/Excalidraw presentes. |
| D1-04 | README com objetivos e execução | I | Raiz e app documentam arquitetura e execução local; ressalva operacional A01. |
| D1-05 | Relatório de análise de vulnerabilidades do scan | P | `docs/vulnerability-report.md:3-5,47-57,195` refere-se a 14/09/2026 e commit anterior; não sustenta conclusão atual de zero vulnerabilidades, contradita pelo restore desta sessão. |
| D1-06 | PDF com grupo, participantes e Discord | P | `docs/delivery/TECH_CHALLENGE_FASE_3_ENTREGA.md:10-16` identifica Grupo 274 e Davi Holanda; não registra username Discord. |
| D1-07 | Vídeo até 15 min e documento da fase 1 | NC | Não foi localizado link de vídeo ou PDF específico de fase 1 nos entregáveis examinados. Isso não prova ausência de submissão histórica fora do repo. |
| D2-01 | README: solução, arquitetura, local/K8s/Terraform/deploy | I | `catcar-app/README.md:51-148,155-221` e READMEs de infra. |
| D2-02 | Collection completa ou Swagger/similar | P | OpenAPI existe em Development; collection Postman ligada aos READMEs contém rotas incompatíveis com o código, conforme A07. |
| D2-03 | Vídeo deploy/CI/API/autoscaling <=15 min | NC | Não localizado URL nos entregáveis examinados; conteúdo/duração não verificáveis. |
| D2-04 | PDF com repo, arquitetura, vídeo e acesso | P/NC | Há PDF consolidado da fase 3, não evidência específica de entrega histórica da fase 2; vídeo/submissão não comprovados. Acesso GitHub confirmado. |
| D3-01 | Componentes: cloud, API, banco e monitoramento | I | `docs/architecture/cloud-components.md:3-32`. |
| D3-02 | Sequências autenticação e abertura OS | I | `docs/architecture/auth-sequence.md:3-51`; autorização Customer atual é compatível com abertura e validação de titularidade. |
| D3-03 | RFCs nuvem, banco e autenticação | I | `docs/architecture/rfc/001-cloud-provider-selection.md:1-30`, `002-managed-database.md:1-30`, `003-serverless-auth.md:1-31`. |
| D3-04 | ADRs comunicação, HPA/APIM e topologia | I | `docs/architecture/adr/001-asynchronous-communication-outbox.md:1-25`, `002-hpa-and-apim-scaling.md:1-25`, `003-repository-topology.md:1-46`. |
| D3-05 | Justificativa banco/ER/relacionamentos | I | RFC 002 e `docs/architecture/er-model.md:1-149`. Não se afirma equivalência exaustiva de cada coluna com cada migration. |
| D3-06 | Quatro READMEs com propósito, tecnologia, arquitetura e instruções | I | READMEs dos quatro sub-repositórios presentes com diagramas e instruções próprias. |
| D3-07 | Dockerfiles quando aplicável e pipelines funcionais | P | Dockerfiles da API/Function existem; pipelines definidas, mas conformidade operacional tem bloqueios das seções 3 e 7. |
| D3-08 | Links de APIs e deploys ativos | P/NC | Links API/Postman presentes; collection desalinhada e não foram identificadas URLs comprovadas dos ambientes ativos nos READMEs. |
| D3-09 | Vídeo auth CPF/CI/deploy/APIs/dashboard/logs/traces <=15 min | NC | Sem URL de vídeo no pacote examinado; não foi possível aferir duração ou demonstrações. |
| D3-10 | PDF único com quatro repos, docs, vídeo e avaliador | P | Artefatos MD/HTML/PDF presentes em `docs/delivery/`; links dos repos/docs e identificação existem, vídeo ausente. |
| D3-11 | Avaliador nos quatro repos | C | GitHub confirmou soat-architecture/write nos quatro. Capturas no PDF não substituem nem invalidam essa comprovação real. |
| D3-12 | Entrega efetiva no Portal do Aluno | NC | Não houve acesso ao Portal nem comprovante de submissão localizado no escopo examinado. |

Não se exige retroativamente que PDFs históricos estejam versionados se foram entregues externamente; registra-se apenas que não há prova dessas entregas na evidência disponível. Links não canônicos no `catcar-app/README.md:9-14` apontam a `daviholandas/...`, enquanto os repos oficiais estão em `RiseOn-CatCar`; recomenda-se unificar as referências.

## 9. Achados priorizados e critérios de aceite

### A01 — Bloqueador: publicação atual falha por dependências vulneráveis

**Prova executada:** seção 3.4. AppHost 13.5.4 foi bloqueado por um advisory crítico e um alto, atingindo três pacotes reportados. Isso impede verificar os artefatos Kubernetes e invalida a afirmação de que a topologia Aspire atual está pronta para publicar.

**Aceite:** atualizar o conjunto compatível de SDK/pacotes/ferramenta Aspire, sem suprimir o audit, e obter restore/build/publicação aprovados; inspecionar os recursos renderizados e atualizar a análise de vulnerabilidades com evidência da revisão corrigida. Não se prescreve versão de correção sem confirmar os advisories e a compatibilidade das APIs utilizadas.

### A02 — Alta: CD não comprovado; falha OIDC nos runs de produção

**Prova:** logs e links da seção 7.2, `AADSTS700213`. Success de um workflow com deploy skipped não comprova entrega na nuvem.

**Aceite:** validar/corrigir o vínculo federado com o subject efetivamente apresentado pelo GitHub e obter runs de **push** com deploy/apply concluído em homologação e produção nos quatro repos, acompanhados de smoke dos endpoints. Não executar apply/deploy apenas para completar esta auditoria sem autorização operacional.

### A03 — Alta: contrato de recursos e ambientes divergente

**Prova:** variáveis GitHub, nomes derivados Terraform e fallbacks de workflow da seção 7.3. Produção do app e infra não compartilha hoje a mesma entrada de foundation RG; registry/workspace de homologação também divergem dos nomes IaC padrão.

**Aceite:** fixar um contrato de nomes/outputs/entradas por ambiente e propagá-lo para Terraform, bootstrap, workflows e AppHost; comprovar que app, Function e infra referenciam os mesmos recursos, sem cruzar homologação/produção. `terraform validate` isolado não fecha esse item.

### A04 — Alta: cadeia cloud da Function não está fechada no código de provisionamento

**Prova estática:** `catcar-auth-function/.github/workflows/ci-cd.yml:70-87` usa `az containerapp update`, pressupondo recurso existente. O AppHost configura Function apenas no modo local (`AppHost.cs:11-62`), não nos branches de publicação. Os roots Terraform e scripts de bootstrap examinados não materializam sua criação, settings JWT/conexão, integração de rede privada e permissões. `catcar-database-infra/main.tf:152-157` monta uma connection string com `auth_readonly`, mas não foi localizado CREATE ROLE/GRANT correspondente nas fontes examinadas.

**Limite:** a Function pode existir manualmente no Azure; não houve consulta ao ambiente para confirmar ou excluir essa hipótese. Ter uma secret de conexão não prova que o usuário do banco existe ou que o runtime a recebe.

**Aceite:** provisionamento/configuração reproduzíveis da Function/Container App, usuário de leitura e permissões necessárias; autenticação real através do APIM contra o banco privado, com token aceito pela API e chave/configuração consistentes.

### A05 — Alta: aprovação e conclusão podem avançar sem estoque reservado

**Prova estática:** `SO/Features/WorkOrders/RecordBudgetDecision/RecordBudgetDecisionHandler.cs:40-68` aplica a aprovação/status e publica eventos pela outbox. O consumidor `CI/Features/InventoryReservations/BudgetApproved/BudgetApprovedHandler.cs:77-88` tenta reservar posteriormente e lança exceção se falhar. Não foi localizado feedback compensatório que reverta/bloqueie a OS. Na conclusão, `WorkOrderStatusChangedInventoryHandler.cs:46-52` retorna se não há reserva ativa.

**[INFERENCE] Cenário:** duas OS competem pelo mesmo saldo; a aprovação é aceita e uma reserva falha por insuficiência. Retry da mensageria não garante que o saldo reapareça. A OS pode continuar em execução e ser concluída sem a reserva esperada. Não foi reproduzida concorrência contra PostgreSQL nesta sessão.

**Aceite:** definir e executar comportamento determinístico para falha de reserva, com OS não avançando indevidamente e sem consumo duplicado; demonstrar aprovação → reserva → conclusão e o cenário de insuficiência/reprocessamento com persistência real. Isso não exige antecipar toda a Saga da fase 4.

### A06 — Alta: dashboard não tem contrato de telemetria de negócio demonstrado

**Prova estática:** `workbooks/catcar-dashboard.json:17,39,55`. Volume usa identidade de operação HTTP/log em vez de WorkOrderId. Tempo por status depende de dimensões de duração não localizadas como emitidas no código auditado; a query reconhece Diagnosis/Execution, enquanto o estado de domínio é InDiagnosis/InExecution. Eventos de integração e DTOs de métricas não são automaticamente traces do Application Insights.

**[INFERENCE] Impacto:** painéis podem ficar vazios ou medir cardinalidade/tempos diferentes do ciclo real da OS. A contagem atual restringe POSTs e tenta deduplicar, portanto não é idêntica ao erro histórico de contar toda listagem; ainda não comprova volume de OS de negócio.

**Aceite:** contrato explícito de eventos/dimensões e sua emissão/exportação; confronto de um conjunto conhecido de OS com volume e durações nas três etapas; painel de integração e alerta disparado por falha controlada, com logs/traces correlacionados. Garantir também apply do módulo de alertas, hoje condicionado a IDs nas variáveis (`catcar-kubernetes-infra/.github/workflows/ci-cd.yml:152-165`).

### A07 — Média: collection Postman não executa o contrato de orçamento/aprovação

**Prova estática:** `docs/postman/CatCar_Platform.postman_collection.json:76-79,112` usa `/service-operations/budgets`, `/budgets/{id}/approve`, `/reject` e `/communication/tokens/{token}`. O código expõe emissão em `/work-orders/{id}/budget`, detalhes em `/approval-links/{rawToken}` e decisão em `/approval-links/{rawToken}/decision`.

Âncoras: `SO/Features/WorkOrders/IssueBudget/IssueBudgetEndpoint.cs:16-21`; `Communication/Features/ApprovalLinks/GetApprovalLinkDetails/GetApprovalLinkDetailsEndpoint.cs:18-26`; `Communication/Features/ApprovalLinks/DecideApproval/DecideApprovalEndpoint.cs:22-31`.

**Aceite:** collection/env alinhados às rotas, corpos e mecanismos de autenticação reais; demonstrar o fluxo abrir OS → emitir orçamento → consultar link → aprovar/recusar → acompanhar status. Não confundir presença do schema Postman v2.1 com correção das requisições.

### A08 — Média: proteção de PR admite exceção e a meta de cobertura não é garantida

**Prova:** bypass remoto explícito; checks obrigatórios ausentes; cobertura observada e configuração do CI na seção 3.2.

**Aceite:** impedir bypass incompatível com a regra acadêmica de PR obrigatório; explicitar os domínios críticos e obter evidência >=80% no escopo acordado, incluindo a meta interna do SharedKernel; vincular verificações relevantes ao merge. Não se exige cobertura de 80% de toda infraestrutura gerada como se fosse domínio.

### A09 — Média: solicitação de aprovação pode não ser enviada

**Prova estática:** `Communication/Features/ApprovalLinks/SendApprovalRequest/SendApprovalRequestHandler.cs:29-39` encerra quando não há e-mail; o cadastro permite ausência desse dado. Nos demais casos há chamada ao sender, não prova de entrega.

**Aceite:** tornar explícito como a solicitação obrigatória chega ao cliente quando não há e-mail, ou impedir essa entrada no fluxo que o exige; provar envio de orçamento e avisos de status no provedor configurado. Não foi classificada a ausência de e-mail no estado Received como violação isolada do edital.

### A10 — Alta para entrega: pacote acadêmico e relatório de segurança incompletos

**Prova:** seção 8; vídeo sem URL, identidade Discord ausente e submissão no Portal não comprovada. O relatório de segurança antigo não representa as vulnerabilidades observadas agora.

**Aceite:** atualizar evidências de scan da revisão entregue, links canônicos, vídeo(s) com conteúdo/duração exigidos, identificação e PDF(s) correspondentes às entregas; anexar/comprovar submissão. A permissão do avaliador já está confirmada e não deve permanecer como pendência de acesso.

### Risco adicional de segurança — token de aprovação em logs

O link usa token bearer no caminho; a API habilita `UseSerilogRequestLogging` (`Program.cs:115`). **[INFERENCE]** Sem redaction do caminho, logs HTTP podem registrar a credencial de uso único antes de seu consumo. Não foi observado vazamento nesta auditoria.

**Verificação necessária:** capturar uma requisição controlada de aprovação e comprovar que logs de API/gateway não retêm o token bruto, preservando correlação útil.

## 10. Revalidação dos sete gaps históricos

| Gap anterior | Estado na árvore atual | Evidência/ressalva |
|---|---|---|
| 1 — APIM aceita apenas Customer | Corrigido no código | `apim-policy.xml:34-87` separa políticas para clientes e colaboradores. |
| 2 — faltam PUT/PATCH/DELETE | Corrigido no código | `catcar-kubernetes-infra/main.tf:327-464` inclui esses verbos e OPTIONS. |
| 3 — workbook não provisionado/queries inadequadas | Parcialmente corrigido | Recurso Terraform existe em `main.tf:178-186`; semântica/ingestão de métricas ainda têm A06. |
| 4 — falta tempo de finalização | Corrigido no código | Campo atual é **AverageFinalizationTimeHours**, em `WorkOrderExecutionTimeMetrics.cs:3-10`; cálculo no repositório. Não exigir o nome proposto no relatório antigo. |
| 5 — falta CorrelationId na API | Corrigido no código | `catcar-app/src/Api/Program.cs:92-113`; cadeia distribuída ainda não comprovada. |
| 6 — diagrama Customer versus abertura administrativa | Corrigido no código | `OpenWorkOrderEndpoint.cs:18-41,63-67` permite Customer e valida titularidade. |
| 7 — README sem diagramas/links de APIs | Presença corrigida | Quatro READMEs têm diagramas/links; collection ligada ainda exige correção de contrato em A07. |

As classificações históricas “infraestrutura conforme” e “CI/CD funcional” ficam substituídas, para a revisão auditada, pela distinção entre definição, validação e operação deste documento.

## 11. Critérios de entrada na fase 4

### Fechamento técnico recomendado

1. **Restaurar a capacidade de build/publicação segura** — A01; anexar evidência atual de restore/build, geração/renderização Kubernetes e suíte completa com Docker/PostgreSQL, incluindo E2E.
2. **Fechar o contrato de deploy dos quatro repositórios** — A02/A03/A04; comprovar targets por ambiente, OIDC, Function/banco privado e execuções reais de deploy.
3. **Fechar o ciclo de negócio e suas falhas** — A05/A09; demonstrar orçamento, aprovação/recusa, reserva, consumo e comunicação, inclusive insuficiência e reprocessamento.
4. **Provar observabilidade de negócio** — A06; confrontar dados conhecidos com dashboard e disparar alerta de falha, preservando correlação.
5. **Alinhar contratos e governança** — A07/A08; corrigir Postman, explicitar cobertura e garantir PR obrigatório.
6. **Concluir o pacote acadêmico** — A10; vídeo, identificação, relatório de segurança, PDF e evidência de submissão. Registrar separadamente qualquer comprovação histórica das fases 1/2 que esteja fora do repositório.

### Delimitação da próxima fase

A [fase 4](requirements/Fase_4_Tech_Challenge.md) exige, entre outros pontos, pelo menos três microsserviços independentes, repositório/infra/banco próprios, SQL e NoSQL, integração Mercado Pago, mensageria, Saga com compensações, BDD de fluxo completo e cobertura por serviço. **Essas exigências não foram usadas para reprovar o monólito das fases 1–3 e não foram implementadas nesta auditoria.**

A divisão dos microsserviços deve partir do fluxo de negócio e das falhas esclarecidas acima, não apenas renomear os quatro bounded contexts atuais como serviços. O próximo passo recomendado é fechar os bloqueios de base com evidência; depois, elaborar o plano de fase 4 sobre essa revisão verificável.
