# Encerramento do ambiente Azure efêmero

O ambiente existe para apresentar e gravar a entrega, não para ficar ligado continuamente. A estimativa de referência é cerca de US$ 0,73/h em execução; após a remoção, o objetivo é aproximadamente US$ 0/mês, **não custo zero garantido**: o armazenamento do estado e eventuais recursos ou cobranças residuais permanecem. Confira o Cost Management.

## Antes de destruir

- [ ] Grave e salve o vídeo demonstrando os requisitos e a aplicação.
- [ ] Guarde o link e as evidências da execução de release bem-sucedida.
- [ ] Capture as telas e demais evidências exigidas pela entrega.
- [ ] Confira o plano e confirme que nenhuma evidência ainda depende do ambiente.

A primeira remoção completa ainda não foi exercitada contra uma implantação real. A exclusão do APIM pode ser lenta; reserve dezenas de minutos ou mais e acompanhe o resultado. Em falha parcial, investigue e execute novamente. O script foi verificado com simulações e com uma execução real somente de plano contra estados vazios; o `terraform destroy` dos recursos de aplicação (AKS, APIM, PostgreSQL) só será comprovado na primeira remoção real.

## Comandos

Autentique-se localmente com a Azure CLI e selecione a assinatura correta. Por padrão o script usa a assinatura atual; para fixá-la explicitamente:

```bash
export AZURE_SUBSCRIPTION_ID=b590511a-414a-4b77-9dc7-fee262287b61
make azure-teardown-plan
make azure-teardown CONFIRM=rg-catcar
```

O primeiro comando é somente uma simulação. O segundo exige digitar `rg-catcar` interativamente. Para automação explicitamente autorizada, `./scripts/teardown-azure.sh --apply --confirm rg-catcar --yes` dispensa apenas a confirmação interativa. O script recusa assinaturas diferentes e planos inseguros. Os padrões do backend são `rg-catcar-tfstate`, `stcatcartf3c4128ef` e `tfstate`; sobrescreva-os com `AZURE_TF_STATE_RG`, `AZURE_TF_STATE_STORAGE_ACCOUNT` e `TF_BACKEND_CONTAINER` se o bootstrap usar outros valores.

A ordem é alertas, função, banco e fundação. O plano de fundação seleciona os recursos gerenciados exceto o grupo preservado; a aplicação primeiro desvincula esse grupo do estado. AKS e seus workloads, APIM, PostgreSQL, Key Vault, rede e demais recursos gerenciados são removidos. Estados vazios são ignorados. O script também verifica recursos restantes e o grupo de nós `MC_rg-catcar_*`; investigue qualquer sobra e seu custo.

Permanecem o grupo `rg-catcar` e seus papéis de implantação, o grupo `rg-catcar-tfstate`, a conta e o contêiner de estado Terraform, a aplicação Entra e o ambiente GitHub `azure`. O Key Vault tem proteção contra purge e, ao ser destruído, permanece excluído de forma reversível até o fim da retenção (90 dias), sem cobrança pelo cofre excluído. O provider do APIM remove o serviço definitivamente ao destruir (padrão `purge_soft_delete_on_destroy = true`). O script lista os cofres e APIMs excluídos para inspeção, mas não os purga.

Para implantar novamente, publique uma **nova tag de release `v*` válida** conforme o [processo de release](release-process.md); não é necessário repetir o bootstrap preservado.

## Recriação do Key Vault (verificado)

Foi testado, com um cofre descartável de mesma configuração (RBAC, proteção contra purge, segredos e atribuição de papel `Key Vault Secrets Officer`), o ciclo criar → destruir → criar de novo com o **mesmo nome e state vazio**, que é o que ocorre num release após o teardown. Resultado: o provider recuperou o cofre excluído e recriou os segredos, sem erro de importação e sem precisar de purga; a recriação levou cerca de 5 minutos. O teste usou retenção de 7 dias e um nome `kvtest-*`; não comprova o comportamento do APIM, do AKS nem do PostgreSQL.
