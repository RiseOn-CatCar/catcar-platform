# Plano de implementação e entrega — Fase 4

Objetivo: transformar o monólito modular em três microsserviços independentes coordenados por uma Saga orquestrada, com CI/CD por serviço, e entregar o PDF da Fase 4 até **22/11/2026 às 23:59**. O vídeo fica fora deste plano.

- Requisitos: [`requirements/Fase_4_Tech_Challenge.md`](requirements/Fase_4_Tech_Challenge.md)
- Contratos entre serviços, Saga, nomes e layout: [`architecture/messaging-contracts.md`](architecture/messaging-contracts.md)

## 1. Decisões

| Tema | Decisão | Motivo |
|---|---|---|
| Divisão | `catcar-os-service` (renomeado de `catcar-app`), `catcar-billing-service` e `catcar-execution-service` | Segue os três serviços sugeridos no edital e reaproveita os bounded contexts existentes |
| NoSQL | Billing usa **Marten** (banco de documentos JSONB) no banco próprio `catcar_billing` | O Wolverine tem integração oficial com o Marten (inbox, outbox e Saga); para o MongoDB só existe um pacote comunitário. **Risco aceito:** o motor é o PostgreSQL, por isso a documentação apresenta o modelo de documentos e a justificativa |
| SQL | OS (`catcar_os`) e Execution (`catcar_execution`) usam EF Core no PostgreSQL | Reaproveita o modelo, as migrações e a concorrência por `xmin` |
| Mensageria | RabbitMQ com `WolverineFx.RabbitMQ`, roteamento convencional e `Aspire.Hosting.RabbitMQ` no AppHost | Integrações oficiais; o mesmo broker roda no Aspire, no kind e no AKS |
| Saga | Orquestrada pela `WorkOrderSaga` (classe base `Saga` do Wolverine, estado no EF Core da OS, `TimeoutMessage` para aprovação e pagamento) | Estado, timeouts e compensações explícitos em um lugar; a infraestrutura de Saga já vem pronta |
| Pagamento | Após a aprovação e antes da execução, pelo Mercado Pago (Checkout Pro, webhook com `x-signature`, reconciliação por polling, reembolso) | Uma falha de pagamento ou de execução passa a ter compensação real |
| Contratos | Cada serviço tem cópia local dos tipos, com `[MessageIdentity]` e testes de contrato | Evita uma biblioteca compartilhada que acoplaria as versões |
| Desenvolvimento local | Um AppHost do Aspire na plataforma (`aspire/CatCar.AppHost`) referencia as três APIs | Os serviços não dependem uns dos outros para compilar |
| Deploy | O CI de cada serviço faz deploy em kind dentro do runner, com smoke, em PR e push na `main` | Prova deploy automatizado em Kubernetes sem custo de Azure; AKS fica fora do escopo da Fase 4 |
| Qualidade | SonarCloud (org `riseon`; projetos `riseon_catcar-*-service`, já criados, com `SONAR_TOKEN` configurado) e gate de 80% de cobertura por serviço | Atende "SonarQube ou similar no CI" |
| BDD | Reqnroll no `os-service`: fluxo completo e fluxo de compensação, com os outros serviços simulados pelo modo de teste do Wolverine | É o fluxo completo mais barato de testar e cobre a Saga inteira |

## 2. Fora do escopo (corte para o prazo)

- Deploy no AKS e rotas no APIM para os novos serviços. `release.yml` e `deploy-azure.sh` continuam no layout da Fase 3.
- Testes E2E entre repositórios.
- Troca da leitura direta de clientes pela Auth Function por REST. A tabela continua no banco da OS e fica registrada como dívida técnica.
- Vídeo.

## 3. Execução

| Fase | Entregas | Estado |
|---|---|---|
| F1. Fundação | Repositórios renomeados e criados; submódulos; contratos; projetos SonarCloud e secrets | Concluída em 20/11 |
| F2. Extração (paralela) | `os-service` com Saga, RabbitMQ e BDD; `billing-service` com Marten, links de aprovação, e-mails e pagamentos; `execution-service` com catálogo, estoque e fila de execução; AppHost e scripts da plataforma | Em andamento |
| F3. CI/CD e governança | CI de cada serviço verde (build, testes, ≥80%, Sonar, Trivy, deploy em kind); proteção de branch com checks obrigatórios em todos os repositórios | Pendente |
| F4. Mercado Pago ao vivo | Credenciais de teste do usuário; validação do checkout, webhook e reembolso em sandbox | Aguarda o cadastro |
| F5. Entregáveis | README por serviço (arquitetura, Saga, evidência de cobertura); Swagger e coleção Postman; PDF da Fase 4; PRs, merges e repin | Pendente |

## 4. Riscos

| Risco | Mitigação |
|---|---|
| O Marten pode não ser aceito como NoSQL | Documentar o modelo de documentos, o banco separado e a justificativa técnica |
| Cobertura de 80% no serviço inteiro | Excluir migrations e `Program`; testes de handlers e endpoints |
| Credenciais do Mercado Pago chegarem tarde | Adapter testado com WireMock; sem credencial, o Billing responde `PaymentFailed` e a Saga compensa |
| Webhook do Mercado Pago exige URL pública | Reconciliação por polling |
