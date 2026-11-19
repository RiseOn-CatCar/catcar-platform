# Fases 1–3: status da implementação corretiva

Data: 2026-11-17, revalidado em 2026-11-18 (seção final). Complementa `docs/fases-1-2-3-audit-report.md`. Registra o que foi implementado e verificado na estação local, e o que depende de Azure, Docker ou pessoas.

## Implementado no código e nos repositórios (sem commit/PR ainda)

|Área|Resultado|
|---|---|
|Build/publicação|Aspire 13.6.5 (K8s provider 13.6.5-preview.1.26559.7), `aspire.cli` 13.6.5, restore sem NU1904; `EntityFrameworkCore` 10.0.14 e `MessagePack` 2.5.307 exigidos pelas dependências novas.|
|Gates|`scripts/verify-domain-coverage.cs` (SharedKernel, ServiceOperations/Domain, CatalogInventory/Domain, mínimo 80% por linha); validação helm de Production/LocalKubernetes no CI.|
|Aprovação e estoque|Aprovação comercial não inicia execução; outcome terminal por orçamento (`budget_reservation_outcomes`), outbox transacional do Wolverine, `InventoryReservationFailed`, reconciliação `--reconcile-inventory`.|
|Tempos e telemetria|Duração por etapa (diagnóstico/execução/finalização) sem contar espera como execução, `WorkOrderStatusTelemetryHandler`, médias nulas para legados.|
|E-mail e acesso|E-mail obrigatório para emitir orçamento; sem fallback para `LoggingEmailSender` fora de Development; `--bootstrap-admin`; `--provision-auth-readonly`.|
|Correlação/confidencialidade|`CorrelationId` nos comandos/eventos, bridge Serilog→OpenTelemetry, token de aprovação fora de traces/logs.|
|IaC|Fundação (ACS e-mail, DNS privado `catcar.internal`, ACA environment, APIM policy reescrita, workbook/alerta estruturados), banco (remote state da fundação), novo root `catcar-auth-function/infra`, bootstrap único em `scripts/bootstrap-azure.sh` com credencial OIDC por subject imutável.|
|Pipelines|Superado pelo ajuste de 17/11/2026 (seção abaixo): ambiente Azure único, deploy somente por tag `vMAJOR.MINOR.PATCH` na plataforma, sub-repositórios apenas com CI.|
|Collection|Postman com rotas reais, Vault para tokens de aprovação, casos negativos.|

## Ajuste 17/11/2026: Azure único, Kind e trunk-based

|Área|Resultado|
|:---|:---|
|Ambiente|Um ambiente Azure (`rg-catcar`, state `rg-catcar-tfstate`); Terraform sem variável `environment`; GitHub Environment `azure` só no meta-repo; bootstrap em prévia por padrão, `--apply` explícito.|
|SDK/pacotes|.NET SDK 11.0.100, `net11.0`, matriz de pacotes do plano (EF Core permanece 10.0.15 por exigência do provider Npgsql), Function com `Azure.Functions.Sdk`.|
|Kind|API, Function real, PostgreSQL com PVC retido, Azurite e Mailpit; imagens por digest; `make kind-validate` gera `artifacts/kind/validation.json`.|
|Release|`ci.yml` (Component Checks, Pinned Integration, Release Images, incluindo E2E e Trivy) e `release.yml` (somente tag estrita); imagens de CI aprovadas promovidas ao ACR por digest sem rebuild; barreira APIM cobre toda mutação `/api/v1/**`. Kind é apenas local e não gera evidência de release.|
|Correções encontradas na validação|Logs sem URL (token de aprovação), prontidão HTTP no E2E, fixture do reconciler, política Wolverine 6 de service location e descoberta explícita de `CatalogSnapshotQueryHandlers`.|

Verificado: Kind validado duas vezes (12 checks verdadeiros, `dirty=true`, evidência local, não de release); PostgreSQL reiniciado sem perda de dados; publish de Production offline com imagem por digest e HPA 2–10; Terraform `fmt`/`validate` nos quatro roots; actionlint e testes dos scripts. **Não verificado:** qualquer operação Azure real (primeiro bootstrap/tag), mapeamento de secrets do Helm gerado em nuvem, política APIM em APIM real, aborto de PVC sem Secret em namespace descartável, inspeção visual da UI Mailpit.

O modo PR-head permite validar mudanças coordenadas durante a revisão, mas não autoriza release: após o merge dos componentes, atualizar os gitlinks para commits de `main` com checks push-to-main aprovados antes de criar a tag da plataforma.

## Verificação executada localmente

- `dotnet build CatCar.slnx -c Release`: 0 erros (históricos desta seção são anteriores ao ajuste acima).
- Testes sem Docker/E2E: 368 aprovados (SharedKernel 28, CatalogInventory 84, Communication 59, ServiceOperations 142, Architecture 20, IdentityAccess 35). Auth Function: 17/17.
- Cobertura de linhas do gate, só testes unitários: SharedKernel 100%, ServiceOperations/Domain 89,7%, CatalogInventory/Domain 88,3% (IdentityAccess 79,3%, informativo).
- `dotnet format whitespace --verify-no-changes`: ok.
- `aspire publish` Production e LocalKubernetes + `helm template`: Deployment/Service/ConfigMap/Secret presentes; HPA `autoscaling/v2`, 70%, 2–10 apenas em Production; Service interno com `azure-load-balancer-internal` e IP fixo; sem HPA em Local.
- Terraform 1.17.1: `fmt` e `validate` ok nos quatro roots (fundação, alertas, banco, auth function); workflows YAML e policy APIM XML bem-formados.
- Snapshots de migration sem divergência do modelo (ServiceOperations e CatalogInventory).

## NÃO verificado (pendente)

- **Testes com Docker** (34 de integração PostgreSQL/Wolverine, incluindo rollback transacional, concorrência, provisionador readonly, bootstrap admin, logging) e **E2E**: compilam, nunca foram executados.
- **Azure**: `az` indisponível. States, recursos existentes, prefixos de sub-rede/IP (`10.20.0.0/16` adotado, não o `10.0.x` do plano), backend de produção, import de recursos, plano Terraform sem delete/replace, deploy, HPA sob carga, KQL/workbook/alerta, e-mail real: nada foi aplicado ou observado.
- **Migration `20260915120000_AddWorkOrderLifecycleTracking`**: recebeu os atributos `[DbContext]/[Migration]` que faltavam; se algum banco já tem essas colunas manualmente, o `--migrate` falha por coluna duplicada. Conferir antes do primeiro migrate.
- **Branch protection**: depende do primeiro ciclo de checks válido.
- Aprovação/recusa por link recebido na caixa real continuam passos manuais do smoke.
- Retry automático do Wolverine para `DbUpdateConcurrencyException` está configurado, mas só simulado nos testes.
- Pacote acadêmico (vídeo ≤15 min, Discord, Portal): dependente do responsável; entrega **não** pode ser declarada completa.

## Revalidação 18/11/2026

Docker passou a estar disponível e houve acesso autenticado ao Azure (assinatura `RiseOn`, `b590511a-…`). A assinatura `184b4b25-…` referida pelas variáveis antigas não é acessível; não havia recursos nem state CatCar na assinatura atual, portanto o bootstrap partiu de ambiente vazio.

### Verificações executadas

- `dotnet restore`/`build -c Release` e `dotnet list package --vulnerable --include-transitive`: 0 erros, 0 avisos, nenhum pacote vulnerável (catcar-app e auth function).
- Suíte completa com Docker: 417 testes unitários, de arquitetura e de integração PostgreSQL/Testcontainers (SharedKernel 28, Communication 72, Architecture 20, CatalogInventory 93, ServiceOperations 164, IdentityAccess 40) e 6 E2E aprovados; Auth Function 17/17. Repetido após o upgrade para Aspire 17.0.0 com o mesmo resultado.
- `aspire publish` Production e LocalKubernetes + `helm template`: Deployment, Service, ConfigMap e Secret; HPA `autoscaling/v2` 2–10 com CPU e memória a 70% apenas em Production; Local referencia o Secret externo `catcar-local-runtime`.
- Relatório de vulnerabilidades refeito (`docs/vulnerability-report.md`): NuGet sem achados, Semgrep (`p/csharp`, `p/security-audit`) 0 achados, Trivy API 0 CRITICAL/0 HIGH, Trivy Function sem achados.
- Collection Postman: 35 requisições conferidas contra o mapeamento real dos endpoints, sem divergência de método, rota ou corpo (conferência estática; não executada contra um ambiente).

### Situação por achado

|Achado|Situação|Evidência / pendência|
|:---|:---|:---|
|A01 build/publicação|Resolvido|Aspire hosting, CLI e publicador Kubernetes 17.0.0 (cliente Npgsql EF 13.6.5, última estável); AppHost migrado de `Aspire.AppHost.Sdk` (ASPIRE012) para `Microsoft.NET.Sdk`. Verificações acima.|
|A02 CD/OIDC|Parcial|Bootstrap aplicado: RGs `rg-catcar`/`rg-catcar-tfstate`, state `stcatcartf3c4128ef`, app `catcar-github-azure-deploy` com credencial federada exatamente `repo:RiseOn-CatCar@330941078/catcar-platform@1376139605:environment:azure`, papéis no escopo do RG, environment `azure` restrito a tags `v*`, 10 variáveis e 7 secrets. Provedores de recursos necessários registrados. **Nenhum release por tag executado**: login OIDC real, deploy e smoke continuam não comprovados.|
|A03 contrato de ambiente|Resolvido|Contrato único no IaC/scripts/AppHost. GitHub limpo: componentes sem environments nem variáveis (são só CI); plataforma só com o environment `azure`; variáveis de repositório obsoletas (`catcar-homolog`, assinatura antiga, client ID antigo) removidas.|
|A04 Function|Resolvido no código|Root `catcar-auth-function/infra`, ACA interno, `--provision-auth-readonly`, chave JWT compartilhada via Key Vault. Execução em Azure pendente do primeiro release.|
|A05 reserva de estoque|Resolvido|Aprovação não inicia execução; execução exige reserva confirmada; falha devolve a OS ao diagnóstico; testes de integração PostgreSQL executados. Ordens legadas são reconciliadas pelo Job `--reconcile-inventory` do release, com a barreira APIM bloqueando mutações durante o deploy.|
|A06 dashboard|Resolvido no código|Workbook e alerta consomem `WorkOrderOpened`/`WorkOrderStageCompleted`/`WorkOrderIntegrationFailed` emitidos pela aplicação; volume diário passou a contar `WorkOrderId` distintos (catcar-kubernetes-infra PR #11). Ingestão e disparo de alerta pendentes do release.|
|A07 Postman|Resolvido|Rotas, corpos e autenticação alinhados; ver verificação acima.|
|A08 governança/cobertura|Parcial|Gate `verify-domain-coverage.cs` (≥80% em SharedKernel, ServiceOperations/Domain, CatalogInventory/Domain) no CI. **Proteção de branch não alterada por decisão do responsável**: bypass de PR para `daviholandas` e nenhum check obrigatório nos cinco repositórios.|
|A09 e-mail|Resolvido no código|E-mail obrigatório para emitir orçamento; notificação sem destinatário falha de forma explícita; sem `LoggingEmailSender` fora de Development. Entrega real pendente do release.|
|A10 pacote acadêmico|Parcial|Relatório de vulnerabilidades atual; ADR 003, entrega MD/HTML e links do README alinhados ao modelo atual. Vídeo, username Discord, PDF regenerado e comprovante do Portal dependem do responsável.|
|Token de aprovação em logs|Resolvido na API|URL removida dos logs Serilog e das tags de Activity, com teste de integração. O APIM não tem diagnóstico/logger configurado no Terraform, então não registra URLs; se um diagnóstico for adicionado, o caminho com token precisa ser excluído.|

### Divergências com o edital ainda abertas

- A fase 3 pede deploy automático por branch para homologação e produção; o projeto adotou deliberadamente um único ambiente Azure com release por tag. Justificar na entrega.
- A fase 1 pede repositório privado; os cinco repositórios continuam públicos.

### Próximo passo operacional

Com os gitlinks da plataforma apontando para commits de `main` com checks de push aprovados, criar a tag `vMAJOR.MINOR.PATCH` para executar o primeiro release (gera custo Azure) e anexar a evidência de deploy, smoke, workbook e alerta.
