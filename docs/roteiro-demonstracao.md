# Roteiro de demonstração (ambiente local)

Roteiro para avaliar os fluxos principais do Balaio ponta a ponta. A configuração inicial (`.env`, chaves JWT, SMTP) está em [README.md](../README.md), seção "Primeiro uso".

Cada passo indica o resultado esperado. Passos marcados como **PENDENTE** dependem de algo que ainda não está disponível neste ambiente.

## Pré-requisitos

- Docker Desktop em execução.
- `.env` criado a partir de `.env.example`, com as variáveis do README.
- Credenciais sandbox do Mercado Pago: **PENDENTE** (necessárias só para o passo 5).

## 1. Subir o ambiente completo

```bash
cd platform
docker compose --profile extended up -d --build
docker compose ps
```

Esperado: todos os serviços com status `healthy` (ou `running` nos bancos sem healthcheck próprio). O perfil `extended` inclui eventos, comunidade e commerce.

Frontend: http://localhost:4321 · Gateway: http://localhost:8080

## 2. Catálogo público (visitante)

1. Abra http://localhost:4321.
   Esperado: a home lista peças publicadas, vindas do catálogo pelo gateway.
2. Chamada direta: `GET http://localhost:8080/api/v1/pecas`.
   Esperado: envelope `{ dados, erro, paginacao }`.
3. Busca: abra `/search` e filtre por técnica.
   Esperado: somente peças da técnica escolhida. Filtro sem resultado mostra o estado vazio.
4. Peça inexistente: abra `/pieces/nao-existe`.
   Esperado: erro de "não encontrada" (HTTP 404 na API).

## 3. Perfil público do artesão

1. `GET http://localhost:8080/api/v1/artesaos` lista os perfis públicos.
2. Abra `/artisans/{slug}` com um slug da lista.
   Esperado: perfil e peças ativas. Nenhum e-mail, configuração ou dado privado aparece.
3. `GET http://localhost:8080/api/v1/artesaos/nao-existe` → 404 `RECURSO_NAO_ENCONTRADO`.

## 4. Conta do comprador e endereços (PI-189)

1. Cadastre um comprador pela tela de cadastro ou por `POST /api/v1/auth/cadastro`.
2. Entre com a conta criada.
3. Cadastre um endereço em `POST /api/v1/usuario/enderecos`. O campo `bairro` deve trazer bairro, cidade e estado separados por vírgula, por exemplo `Boa Vista, Recife, PE`.
   Esperado: o primeiro endereço fica como principal.
4. Com outra conta de comprador, `GET /api/v1/usuario/enderecos/{id}` do endereço anterior.
   Esperado: 404. Um comprador não vê endereços de outro.

## 5. Checkout e pagamento (PENDENTE)

Sem credenciais sandbox, `POST /api/v1/checkout` responde 503 `PAGAMENTO_INDISPONIVEL`. Esse é o comportamento esperado enquanto o sandbox não está configurado.

Com as credenciais em `.env` e o commerce reiniciado:

1. Adicione peças à sacola.
2. Escolha um endereço salvo no checkout.
3. Conclua o pagamento no ambiente sandbox do Mercado Pago.
4. Acompanhe o pedido na conta do comprador.

## 6. Administração (curadoria)

1. Entre com a conta administradora definida em `ADMIN_EMAIL` e `ADMIN_SENHA_INICIAL` (valores do `.env`, não versionados).
2. Acesse a fila de curadoria de selos (`GET /api/v1/admin/curadoria`).

## 7. Coletivos

1. Como administrador, crie um coletivo em `POST /api/v1/coletivos` com membros já cadastrados como artesãos.
2. `GET /api/v1/coletivos/{slug}` retorna os membros e as peças publicadas de cada um, vindas do catálogo.

## 8. Comunidade e eventos (perfil `extended`)

- Vídeos: `GET http://localhost:8080/api/v1/videos`.
- Eventos: `GET http://localhost:8080/api/v1/eventos`.

Esperado com o perfil `extended` ativo: listas carregadas.
Sem o perfil `extended`: erro nessas páginas. A home continua funcionando.

## Documentação da API (OpenAPI)

Cada serviço publica a especificação em `/v3/api-docs` e a interface em `/swagger-ui.html`:

| Serviço | Porta | Especificação |
|---|---|---|
| catalog-service | 8081 | http://localhost:8081/v3/api-docs |
| profile-service | 8082 | http://localhost:8082/v3/api-docs |
| commerce-service | 8083 | http://localhost:8083/v3/api-docs |
| community-service | 8084 | http://localhost:8084/v3/api-docs |
| events-service | 8085 | http://localhost:8085/v3/api-docs |

O gateway (`8080`) não tem especificação própria. Suas rotas são a soma das rotas dos serviços acima, definidas em `api-gateway/src/main/resources/application*.yaml`.

Os endpoints de documentação ficam acessíveis sem autenticação. As rotas de negócio exigem o Bearer JWT indicado na especificação.

## 9. Encerrar

```bash
cd platform
docker compose --profile extended down
```

Atenção: `docker compose down -v` remove também os volumes, com os dados de todos os bancos.

## Evidências a registrar

- Captura da home com peças do catálogo.
- Resposta de `GET /api/v1/pecas` com `paginacao`.
- Resposta 404 de endereço de outro comprador (passo 4).
- Captura do checkout concluído no sandbox (**PENDENTE**).
- Captura da fila de curadoria (passo 6).

## Pendências conhecidas

- **HTTPS:** o ambiente atual é apenas HTTP. Ver PI-53.
- **Checkout:** depende das credenciais sandbox do Mercado Pago (passo 5).
- **OpenAPI:** não publicado para todos os serviços.
- **Revisão visual:** home, busca e estados de erro e vazio ainda não foram conferidos no navegador.
