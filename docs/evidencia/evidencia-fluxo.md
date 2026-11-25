# Evidência de funcionamento (item 3.4)

Coletada em 24/11/2026 (horário local, UTC-3), na pilha `docker compose -f docker-compose.yml -f docker-compose.simulador.yml --profile extended`, com o `commerce-service` na branch `feat/paralelismo-email-painel` e o pagamento simulado ativo (`balaio.pagamento.simulador.ativo=true`). Pedido de teste: `72618202-ac8d-40e1-af85-b0a10141654f`.

## 1. Fluxo pelo gateway

O script `scripts/test-gateway-commerce-integration.ps1 -ParaAntesDoAdmin` executa as chamadas pelo gateway (`localhost:8080`) e imprime cada verificação aprovada com o horário. A saída completa está em `fluxo-saida.txt`.

- `OK 2026-11-24T22:59:11.139-03:00 | token interno configurado`
- `OK 2026-11-24T22:59:11.470-03:00 | cadastro do artesão pelo Gateway`
- `OK 2026-11-24T22:59:11.697-03:00 | cadastro do comprador pelo Gateway`
- `OK 2026-11-24T22:59:11.738-03:00 | publicação de peça única pelo Gateway`
- `OK 2026-11-24T22:59:11.941-03:00 | checkout e reserva`
- `OK 2026-11-24T22:59:11.946-03:00 | preço e frete calculados no servidor`
- `OK 2026-11-24T22:59:12.173-03:00 | cadastro do segundo comprador`
- `OK 2026-11-24T22:59:12.202-03:00 | segunda compra da peça única recusada`
- `OK 2026-11-24T22:59:12.236-03:00 | replay idempotente do checkout`
- `OK 2026-11-24T22:59:14.291-03:00 | pagamento simulado exige token`
- `OK 2026-11-24T22:59:16.363-03:00 | confirmação simulada consome reserva`
- `OK 2026-11-24T22:59:16.387-03:00 | pedido aparece no painel do ateliê`
- `OK 2026-11-24T22:59:16.406-03:00 | venda aparece para o ateliê`
- `OK 2026-11-24T22:59:16.413-03:00 | comprador não consulta pedidos do artesão`
- `OK 2026-11-24T22:59:16.432-03:00 | artesão não consulta lista de compradores`
- `OK 2026-11-24T22:59:16.437-03:00 | vendas exigem autenticação`
- `OK 2026-11-24T22:59:16.463-03:00 | produção restrita ao ateliê`
- `OK 2026-11-24T22:59:16.479-03:00 | pedido aceito saiu da fila pendente`
- `OK 2026-11-24T22:59:16.501-03:00 | mediação após produção`
- `OK 2026-11-24T22:59:16.535-03:00 | abertura de mediação pelo comprador`
- `PEDIDO 72618202-ac8d-40e1-af85-b0a10141654f`

Pontos verificados:
- **Checkout e reserva:** o checkout devolve `aguardando_pagamento`, com total de 138,90 calculado no servidor.
- **Segunda compra da peça única:** recusada (409).
- **Replay idempotente:** mesmo pedido devolvido.
- **Pagamento simulado:** exige token interno; com token, confirma o pagamento e consome a reserva.
- **Painel e vendas do artesão:** o pedido aparece para o artesão e não para o comprador.
- **Produção:** restrita ao artesão.
- **Mediação:** o comprador abre a mediação após a produção.

## 2. Estado do pedido (commerce-db)

Pedido `producao`, total 138,90, meio `checkout_pro`. Etapas registradas:

| Estado | Título | Criada em (UTC) |
|---|---|---|
| aguardando_reserva | Situação do pedido | 01:59:11.853 |
| aguardando_pagamento | Situação do pedido | 01:59:11.883 |
| confirmacao_pendente | Situação do pedido | 01:59:16.334 |
| confirmado | Pedido confirmado | 01:59:16.354 |
| producao | Em produção | 01:59:16.451 |

## 3. Reserva no catálogo (commerce → catalog)

No catalog-db, a peça do item do pedido (`vaso-qa-pi190-2f7d633658`) está com reserva `CONSUMIDA` para este pedido. A reserva foi criada e consumida por chamadas internas do commerce ao catalog-service.

## 4. Fila de e-mails e envio (commerce → profile → SMTP)

Dois e-mails na fila, ambos enviados às 01:59:31, na primeira tentativa após a confirmação:

| Evento | Destinatário | Estado | Enviado em (UTC) | Erro |
|---|---|---|---|---|
| pagamento_confirmado | artesao | enviado | 01:59:31.974 | — |
| pagamento_confirmado | comprador | enviado | 01:59:31.955 | — |

O endpoint interno `GET /internal/v1/pedidos/{id}/emails` devolve a mesma situação. No Mailpit, as duas mensagens chegaram aos endereços que o profile-service devolveu para as contas (`artesao-2f7d633658@example.test` e `comprador-2f7d633658@example.test`), com o número do pedido no assunto. Isso comprova a chamada commerce → profile pelo efeito no destinatário.

Observação: antes desta execução, os e-mails falharam com `MailSendException` porque o container do commerce estava com o host SMTP `localhost`. Depois de recriado com `host.docker.internal`, a entrega funcionou. Uma falha isolada logo após o start não teve causa confirmada. Os e-mails desta evidência foram enviados sem erro.

## 5. Mediação (community → commerce)

No community-db, a mediação do pedido está `aberta` (id `989006e3-3eda-476c-b0aa-a952a8848a34`). O pedido só pode ser mediado depois de estar em produção, e a mediação foi criada com sucesso (201). Esse sucesso depende de o community-service consultar o pedido no commerce, mas esta evidência não isola essa chamada; é um indício, não uma prova direta.

## O que esta evidência não comprova

- **Logs de chamadas HTTP entre serviços:** os serviços não registram as chamadas internas em log (não há access log). A comunicação é comprovada pelos efeitos nos bancos e nas mensagens, não por linhas de log.
- **Decisão da mediação:** a mediação foi aberta, mas não decidida. Decidir exige login de administrador, que a conta exige troca de senha.
- **Drenagem da fila nos modos sequencial e paralelo, via endpoint:** o endpoint foi demonstrado para este pedido. A comparação de tempo entre os modos está nos benchmarks em `docs/benchmark`, não nesta execução.
- **Pagamento real:** o pagamento foi simulado (`balaio.pagamento.simulador.ativo=true`), sem Mercado Pago.
