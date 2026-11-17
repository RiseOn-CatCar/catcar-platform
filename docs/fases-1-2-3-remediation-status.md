# Fases 1–3: status da implementação corretiva

Data: 2026-11-17. Complementa `docs/fases-1-2-3-audit-report.md`. Registra o que foi implementado e verificado na estação local, e o que depende de Azure, Docker ou pessoas.

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
|Release|`ci.yml` (Component Checks, Pinned Integration, Kind Validation) e `release.yml` (somente tag estrita); imagens aprovadas promovidas ao ACR por digest sem rebuild; barreira APIM cobre toda mutação `/api/v1/**`.|
|Correções encontradas na validação|Logs sem URL (token de aprovação), prontidão HTTP no E2E, fixture do reconciler, política Wolverine 6 de service location e descoberta explícita de `CatalogSnapshotQueryHandlers`.|

Verificado: Kind validado duas vezes (12 checks verdadeiros, `dirty=true`, evidência local, não de release); PostgreSQL reiniciado sem perda de dados; publish de Production offline com imagem por digest e HPA 2–10; Terraform `fmt`/`validate` nos quatro roots; actionlint e testes dos scripts. **Não verificado:** qualquer operação Azure real (primeiro bootstrap/tag), mapeamento de secrets do Helm gerado em nuvem, política APIM em APIM real, aborto de PVC sem Secret em namespace descartável, inspeção visual da UI Mailpit.

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
