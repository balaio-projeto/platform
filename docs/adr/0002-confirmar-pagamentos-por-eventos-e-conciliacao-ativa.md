# ADR 002: Confirmar pagamentos por eventos guardados no PostgreSQL e por conciliação ativa com o Mercado Pago

- **Status:** Proposta
- **Data:** 23/11/2026
- **Autor:** Gabriel
- **Serviço afetado:** `commerce-service` (e, de tabela, a reserva de peças no `catalog-service`)

## Atributo de qualidade

Escolhi **Confiabilidade → Tolerância a falhas** (ISO/IEC 25010:2023).

Pra mim, o momento mais delicado do Origem é o pagamento. O comprador paga a peça lá no Mercado Pago, fora do nosso sistema, e a gente só fica sabendo que deu certo quando o Mercado Pago avisa o `commerce-service` pelo webhook. No meio desse caminho tem o gateway, o commerce, o catálogo segurando a peça única por 15 minutos e um provedor externo que a gente não controla. Qualquer um desses pode cair ou demorar, e o aviso pode chegar duas vezes, chegar atrasado ou simplesmente não chegar.

Do lado de quem usa, o comprador espera ver o pedido como pago assim que o dinheiro sai da conta dele. O artesão precisa receber o pedido pra começar a produzir, e a peça única não pode ser vendida pra duas pessoas.

**Se a arquitetura não der conta disso**, o comprador é cobrado e o pedido fica travado em "aguardando pagamento", ou pior, é cancelado por expiração. A reserva da peça cai e outra pessoa pode comprar a mesma peça. O artesão perde a venda ou começa a produzir sem saber se vai receber, e quem administra tem que abrir o painel do Mercado Pago e conferir pagamento por pagamento, estornando na mão. Num marketplace que ainda está conquistando os primeiros artesãos e compradores, cobrar alguém sem entregar o pedido é o tipo de coisa que queima a confiança rapidinho.

## Cenário de qualidade

| Parte | Descrição |
| --- | --- |
| Fonte do estímulo | O Mercado Pago |
| Estímulo | Aprova o pagamento de um pedido com peça única, mas o aviso (webhook) não chega ao `commerce-service`: ou se perde, ou é mandado enquanto o serviço está fora do ar |
| Artefato | O fluxo de confirmação de pagamento do `commerce-service` (webhook, conciliação e mudança de estado do pedido) e a reserva da peça no `catalog-service` |
| Ambiente | Modo degradado: o `commerce-service` fica até 5 minutos fora do ar (queda ou deploy) num dia normal, com o Mercado Pago e o catálogo funcionando |
| Resposta | Quando volta, o commerce vai atrás do pagamento sozinho, perguntando ao Mercado Pago pela referência do pedido. Ele marca o pedido como pago e confirma a reserva da peça. Se o webhook aparecer depois, repetido ou fora de ordem, nada é confirmado duas vezes |
| Medida da resposta | O pedido aparece como "pago" em até 2 minutos depois que o serviço volta, em 100% dos casos testados, sem nenhum pedido pago cancelado por expiração e sem nenhuma confirmação ou baixa de estoque duplicada |

**Juntando tudo:** imagina que o `commerce-service` ficou uns 5 minutos fora do ar num dia normal e, bem nessa hora, o Mercado Pago aprovou o pagamento de uma peça única. O aviso se perdeu. Quando o serviço volta, ele mesmo vai perguntar ao Mercado Pago pela referência do pedido, descobre que foi pago, marca o pedido e confirma a reserva no catálogo. Se o webhook chegar depois, repetido ou fora de ordem, nada acontece duas vezes. Eu considero que passou se o pedido estiver como "pago" em até 2 minutos depois que o serviço voltou, em todos os casos testados, sem nenhum pedido pago cancelado e sem nenhuma confirmação duplicada.

## Contexto

O Origem (repositórios `balaio-projeto`) é dividido em serviços Spring Boot: gateway, profile, catalog, commerce, community e events, cada um com seu PostgreSQL. A equipe é pequena, todo mundo faz outras disciplinas ao mesmo tempo, o prazo é de um semestre e não tem dinheiro pra infraestrutura. A stack foi combinada com Desenvolvimento Web e o modelo de dados com Banco de Dados.

O pagamento é pelo Checkout Pro do Mercado Pago. O comprador paga fora do Origem, e o commerce só fica sabendo pelo webhook `POST /api/v1/pagamentos/mercado-pago/notificacoes`. A peça única fica reservada no catálogo por 15 minutos.

Olhando o código, boa parte disso já existe. Cada aviso que chega é guardado na tabela `pagamento_notificacoes` (com chave `request_id` + `pagamento_id` e `ON CONFLICT DO NOTHING`), e um worker que roda a cada 10 segundos (`PagamentosAgendados`) processa o que estiver pendente e confere os pagamentos que a gente já conhece.

**O problema que eu encontrei:** se o webhook se perde, o commerce nem sabe qual é o `pagamento_id`. Aí ele só vai procurar o pagamento pela referência do pedido depois de 16 minutos (`pagamentosExpirados`), quando a reserva de 15 minutos já venceu. Resultado: o pedido vai para estorno em vez de virar venda.

**O que mais me preocupa aqui:** tolerância a falhas, pagamento e pedido batendo, não processar nada duas vezes, custo de infraestrutura, prazo e conseguir rastrear o que aconteceu.

## Decisão

Minha proposta é tratar a confirmação de pagamento como **um fluxo orientado a eventos dentro do próprio `commerce-service`**. O webhook só confere a assinatura, guarda o aviso no PostgreSQL e responde 200. Quem faz o trabalho de verdade é um worker agendado, que lê os avisos pendentes e tenta de novo quando algo falha.

E, pra fechar o buraco que encontrei, **o mesmo worker passa a ir atrás do pagamento no Mercado Pago**, pela `external_reference`, sempre que um pedido estiver há mais de 1 minuto esperando sem ter recebido aviso nenhum. Sem esperar a expiração.

**Padrão:** Orientado a Eventos, mas sem broker. A "fila" é uma tabela no PostgreSQL que o serviço já usa.

**Táticas que vou usar de fato:**

- **Processamento assíncrono:** o webhook só anota que o pagamento aconteceu; o pedido é atualizado depois, fora da requisição.
- **Intermediário (fila):** a tabela `pagamento_notificacoes`, com `proxima_tentativa_em`, `tentativas` e `ultimo_erro`.
- **Degradação graciosa do consumidor:** se o worker estiver fora do ar ou der erro, o aviso continua guardado esperando, e a busca ativa cobre o aviso que nunca chegou.

Deixei de fora "replicar consumidores pra escalar", porque isso não muda nada na medida do meu cenário.

## Justificativa

O ponto principal é que o webhook deixa de ser o único jeito de descobrir um pagamento. Se ele se perder ou chegar com o serviço fora do ar, a busca ativa acha o pagamento logo nos primeiros ciclos do worker depois que o commerce volta (o ciclo é de 10 segundos e a busca começa com 1 minuto). Isso cabe nos 2 minutos do cenário e acontece bem antes de a reserva de 15 minutos vencer.

Como o aviso é guardado antes de qualquer outra coisa, se algo falhar no meio do caminho o worker só remarca a tentativa (`proxima_tentativa_em`) e o aviso não se perde. Se o webhook chegar repetido, atrasado ou fora de ordem, ele esbarra na chave única da tabela e nas travas da mudança de estado do pedido, que pegam primeiro o pedido e depois a intenção de pagamento, na mesma transação. A confirmação da reserva no catálogo também usa chave de idempotência (`confirmar:{reservaId}`), então não tem como confirmar duas vezes.

E, como a fila é só uma tabela no PostgreSQL que o commerce já tem, não preciso subir nenhum serviço novo, o que encaixa com a falta de orçamento.

## Consequências

**O que a gente ganha**

- Nenhum pagamento aprovado fica dependendo de um único webhook.
- Quando algo dá errado, vira uma nova tentativa registrada no banco, e dá pra ver qual foi o último erro.
- Dá pra testar tudo com um PostgreSQL de verdade, sem montar infraestrutura extra.

**O que a gente perde (e eu aceito pagar)**

- **O pagamento não aparece na hora:** o comprador pode ficar vendo "processando" por até 2 minutos.
- **Mais chamadas ao Mercado Pago:** é uma busca por pedido pendente a cada ciclo. Vou precisar limitar quantos pedidos entram por vez e espaçar as buscas, senão a gente bate no limite de requisições deles.
- **Fica mais chato de depurar:** o fluxo não é mais uma chamada só; ele fica espalhado entre o controller, a tabela e o worker.
- **Cuidado com mais de uma réplica:** o worker roda em toda instância do commerce. Se um dia tiver duas, elas não podem processar o mesmo pedido ao mesmo tempo. Hoje quem segura isso é o `SELECT ... FOR UPDATE`.
- **A tabela cresce:** `pagamento_notificacoes` vai acumulando linhas e vai precisar de uma limpeza de tempos em tempos.

## Alternativas que considerei

- **Cliente-servidor síncrono, confirmando só quando o webhook chega:** é o jeito mais simples, mas é justamente o que quebra no meu cenário.
- **Um broker de mensagens (RabbitMQ ou Kafka):** daria entrega garantida e reprocessamento, mas é mais um serviço pra hospedar e cuidar, e a gente não tem dinheiro nem tempo pra isso. Fora que o evento continuaria vindo de um webhook que pode não chegar.
- **CQRS:** separaria leitura e escrita do pedido, mas o meu problema não é ler rápido, é não perder a escrita do pagamento. Ainda duplicaria o modelo de dados que combinamos com Banco de Dados, sem melhorar nada no cenário.
- **Aumentar o tempo de reserva no catálogo:** só esconde o atraso. A peça única ficaria presa mais tempo pra todo mundo, e o pedido continuaria sem ser confirmado.
- **Portas e Adaptadores:** a gente já usa dentro do commerce (o Mercado Pago fica atrás da porta `PagamentoGateway`), mas sozinho ele não traz nenhuma tática de tolerância a falhas.

## Rastreabilidade

- **Código (`commerce-service`):**
  - `payment/api/PaymentWebhookController`;
  - `payment/application/CheckoutProService` (`registrarNotificacao`, `processarNotificacoes`, `reconciliar`, `encerrarPagamentosExpirados`);
  - `payment/scheduling/PagamentosAgendados`;
  - `payment/persistence/PagamentoJdbcRepository`.
- **Banco:** migration `V2__checkout_pro_sandbox.sql` (`pagamento_intencoes` e `pagamento_notificacoes`).
- **Configuração:** `payment.mercadopago.worker-enabled` e `payment.mercadopago.worker-interval-ms` (padrão 10000).
- **Teste que já existe:** `PedidoWorkflowPostgresTest.webhookAssinadoConsultaProvedorERepeticaoNaoDuplicaTransicao`.
- **Cards:** PI-54 (Checkout Pro sandbox) e PI-193 (encerramento e liberação de reserva).
- **Atributo:** Confiabilidade → Tolerância a falhas. **Padrão:** Orientado a Eventos.

## Como eu vou verificar

Vou escrever um teste de integração novo em `PedidoWorkflowPostgresTest`, com PostgreSQL de verdade e com o Mercado Pago e o catálogo simulados:

1. Crio o checkout de uma peça única e aprovo o pagamento no simulador **sem chamar o webhook**.
2. Volto 5 minutos nos horários da intenção de pagamento, pra simular o tempo em que o serviço ficou fora.
3. Rodo os ciclos do worker que equivalem a 2 minutos e confiro se o pedido está "pago", se a reserva foi confirmada uma vez só e se nenhum estorno foi pedido.
4. Mando o webhook atrasado duas vezes e confiro se o estado, as etapas do pedido e as chamadas ao catálogo continuam iguais.

O teste roda na CI do commerce com `COMMERCE_POSTGRES_TEST=true`. Enquanto a busca ativa não existir, o passo 3 tem que falhar, e isso já serve de prova do problema que descrevi no Contexto.
