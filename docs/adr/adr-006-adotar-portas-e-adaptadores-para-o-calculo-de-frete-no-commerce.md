# ADR-006: Adotar Portas e Adaptadores para o cálculo de frete no commerce.

- **Status:** Aceita
- **Data:** 2026-11-23
- **Autor:** LUCAS CHAVES SAMPAIO FERRER (lcsf2@cesar.school)
- **Turma:** Embarque (segundas)
- **Projeto:** Origem · marketplace da economia criativa e do artesanato de Pernambuco

## Contexto

O commerce do Balaio calcula o frete em um módulo próprio, que depende de um provedor externo: o Melhor Envio, em sandbox, e uma opção fixa de demonstração. Um administrador pode pedir a troca do provedor de cálculo do frete no checkout. A equipe tem seis integrantes, um semestre de prazo e divide o tempo com outras disciplinas. O servidor é próprio, sem custo, e não tem limite no momento, porque ainda não há usuários.

## Preocupações

modificabilidade, custo de mudança, prazo.

## Decisão

O cálculo do frete fica atrás da porta ProvedorFrete, e cada provedor é implementado por um adaptador. O pedido depende apenas da porta FretePedido, sem conhecer o provedor.

## Justificativa

O cenário da etapa 2 exige que a troca do provedor de cálculo do frete seja feita em no máximo um serviço, sem alterar o código de pedidos nem o de catálogo, em até cinco dias úteis. Com a porta, a troca fica restrita a um novo adaptador. O pedido não muda, porque recebe FretePedido, implementado por FreteDoPedidoAdapter, que delega ao FreteService. As táticas que afetam esse esforço são encapsular a dependência externa, usar intermediário (a porta) e inverter e injetar a dependência. Isolar a dependência para teste e adiar a vinculação não reduzem o esforço da troca e não foram considerados. Mudanças na regra de cálculo, fora do provedor, não são cobertas por esta decisão.

## Consequências

Ganha-se o isolamento da troca de provedor e a possibilidade de trocar sem alterar o pedido. Perde-se: mais arquivos por integração (porta, adaptador e tradução de dados), a necessidade de mapear o modelo do domínio para o de cada adaptador e uma curva maior para quem entra no projeto. O ganho só se mantém se a regra de dependência for respeitada: o domínio não deve passar a depender de detalhes de banco ou de HTTP.

## Alternativas consideradas

Camadas. Foi descartado porque a dependência vertical faz a troca de provedor atravessar as camadas até chegar ao pedido, o que contraria o cenário de mudança restrita a um serviço e sem tocar em pedidos. Camadas é mais simples de implementar e de entender para quem entra no projeto, e isso foi considerado na decisão.

## Rastreabilidade

**Atributo de qualidade:** Manutenibilidade · Modificabilidade

**Cenário que originou a decisão:**

> Um administrador pede para trocar o provedor de cálculo do frete no checkout. Em ambiente de desenvolvimento, fora de operação, a equipe conclui a troca alterando no máximo um serviço: implementa um novo adaptador do provedor e não toca no código de pedidos nem no de catálogo. A mudança é entregue em até cinco dias úteis

**Padrão arquitetural adotado:** Portas e Adaptadores

**Táticas empacotadas:** Encapsular a dependência externa; Usar intermediário (a porta); Inverter e injetar dependência

Módulo shipping do commerce (FreteService, ProvedorFrete, MelhorEnvioClient, FreteFixoDemonstrativo), a porta FretePedido com o adaptador FreteDoPedidoAdapter no módulo order, e o teste MelhorEnvioClientTest

## Verificação

- **Teste do cenário:** O cenário é evidenciado em parte por dois testes. O MelhorEnvioClientTest exercita o adaptador do provedor de forma isolada, com servidor HTTP simulado, e verifica a cotação, o tratamento de token recusado e o uso da cotação fixa quando não há token. O caso TC30, "Frete sandbox", do cenário TS16 do plano de testes, exercita o provedor em sandbox e prevê a indisponibilidade do provedor e a cotação vencida. Não há caso que troque o provedor de ponta a ponta nem que meça o prazo de cinco dias úteis, e essa lacuna fica registrada aqui.

---

_Gerado pelo estudo dirigido de Arquitetura de Software · ADS020 · 2026.2._
