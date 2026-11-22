# Platform Balaio

Ambiente de desenvolvimento local do Balaio. Cada aplicação tem seu repositório e sua imagem. O Compose monta a rede, os bancos PostgreSQL e os containers que você escolher iniciar.

## Repositórios lado a lado

```text
Repo/
├── Balaio-Front/Frontend/  # https://github.com/balaio-projeto/Balaio-Front
├── api-gateway/
├── catalog-service/
├── profile-service/
├── commerce-service/
├── community-service/
├── events-service/
└── platform/
```

## O que é configurado automaticamente

O `Dockerfile` de cada serviço constrói sua imagem e declara a porta interna; ele não cria banco nem publica portas no computador. O `docker-compose.yml` dá nome aos containers, conecta todos na mesma rede, publica as portas e fornece ao serviço a URL JDBC, o usuário e a senha do próprio banco. A imagem PostgreSQL cria os bancos e usuários na primeira inicialização dos respectivos volumes. O catálogo usa também seu script de inicialização para criar o banco e o usuário da aplicação.

As portas internas e os nomes usados entre containers permanecem fixos. As portas dos bancos publicadas pelo Compose escutam somente em `127.0.0.1`; outros dispositivos da rede não conseguem acessá-las diretamente. Para mudar apenas a porta acessada pelo computador local, use as variáveis `*_HOST_PORT` do `.env.example`.

## Serviços

| Aplicação | Porta HTTP | Banco e porta no computador | Inicialização padrão |
| --- | ---: | --- | --- |
| Frontend | 4321 | — | Sim |
| api-gateway | 8080 | — | Sim |
| catalog-service | 8081 | catalog-db, 5433 | Sim |
| profile-service | 8082 | profile-db, 5434 | Sim |
| commerce-service | 8083 | commerce-db, 5435 | Opcional |
| community-service | 8084 | community-db, 5436 | Opcional |
| events-service | 8085 | events-db, 5437 | Opcional |
| seaweedfs | 8333 (somente loopback) | volume seaweedfs-data | Perfil `storage` |

Cada serviço de negócio usa seu próprio banco e volume. O `profile-service` e o Gateway integram a pilha padrão para testes diretos das APIs; o frontend encaminha todas as chamadas da API ao Gateway; não há mais Fake API. Os bancos dos três serviços opcionais são containers separados. O gateway recebe os endereços internos dos cinco serviços mesmo quando algum serviço opcional está parado. As rotas sem implementação no serviço de destino ainda retornarão erro.

## Primeiro uso

Na pasta `platform`, com o Docker em execução, há dois caminhos equivalentes:

```powershell
docker compose --profile extended up --build
```

```powershell
pwsh -File scripts/start-local.ps1
```

O segundo exige PowerShell 7.2+ e faz a mais: cria o `.env` se faltar (com senha de banco e token interno aleatórios), inicia o Docker Desktop se necessário, recusa iniciar se o banco do perfil tiver migrations legadas (veja [Volumes antigos do perfil](#volumes-antigos-do-perfil)), sobe os bancos primeiro e depois faz build e espera a saúde de todos os serviços. Use `-NoBuild` para reaproveitar as imagens e `-Check` para só verificar. Ele nunca remove volumes, redefine senhas, altera históricos Flyway nem atualiza código.

Em ambos, o Compose usa senhas locais demonstrativas para os bancos e um token interno local, e o `profile-service` gera o par JWT RSA num volume: o volume da chave privada é montado só nele, e os demais serviços recebem apenas a chave pública. O `.env` é opcional; as variáveis estão em `.env.example`. Não use esses defaults fora do computador de desenvolvimento. O administrador inicial só é criado se `ADMIN_EMAIL` e `ADMIN_SENHA_INICIAL` (mínimo de 12 caracteres) estiverem no `.env`; contas comuns podem ser cadastradas normalmente.

Para pagar de fato no sandbox, forneça opcionalmente `MERCADOPAGO_ENVIRONMENT=sandbox`, `MERCADOPAGO_ACCESS_TOKEN`, `MERCADOPAGO_WEBHOOK_SECRET`, `MERCADOPAGO_NOTIFICATION_URL` (HTTPS público) e `FRONTEND_RETURN_URL` (HTTPS público). Sem o conjunto completo, o commerce inicia, mas `POST /api/v1/checkout` retorna 503. Configuração parcial ou de produção é recusada. Use conta de teste vendedora e compradora distintas; veja [roteiro PI-54](../commerce-service/docs/PI-54-checkout-pro-sandbox.md). Não versione valores dessas variáveis.

## Pilha completa (perfil extended)

`docker compose --profile extended up --build` inicia frontend, gateway, perfil, catálogo, commerce, community, events e seus bancos, sem SeaweedFS. O frontend encaminha o checkout e o estado de pedidos ao Gateway. As demais telas continuam conforme sua integração atual.

O perfil e o gateway recebem `AUTH_ALLOWED_ORIGINS`, com padrão `http://localhost:4321`. Se mudar `FRONTEND_HOST_PORT`, ajuste essa origem. Para HTTP local, `AUTH_COOKIE_SECURE=false`; em HTTPS, configure `true`. A chave privada JWT local fica no volume `jwt-local-private` acessível apenas ao perfil; a chave pública é publicada no volume `jwt-local-public` para os serviços validadores. O par persiste entre reinícios do Compose.

### Volumes antigos do perfil

Se o volume do profile-service foi criado com as migrations antigas V1 ou V5/V6, o start-local.ps1 recusa iniciar e não altera nada. Siga o procedimento com backup em [docs/migracoes-legadas.md](docs/migracoes-legadas.md).

## Problemas comuns

| Sintoma | Causa e solução |
| --- | --- |
| `path ... Balaio-Front/Frontend not found` no build | O clone do frontend precisa estar em `Repo/Balaio-Front/Frontend`, ao lado de `platform`. Se estiver em outra pasta, defina `FRONTEND_CONTEXT` no `.env` com o caminho relativo a `platform`. |
| `password authentication failed` num banco | O volume já existia com outra senha; o Postgres só lê a senha na criação do volume. Use a senha original em `DB_PASSWORD` ou, se puder perder os dados, `docker compose down -v`. |
| `port is already allocated` | Outra aplicação usa a porta. Mude a variável `*_HOST_PORT` correspondente no `.env`. |
| Erro de versão ao rodar `scripts/start-local.ps1` | Use `pwsh` (PowerShell 7.2+), não `powershell.exe`. |
| Frontend não sobe | Ele espera o gateway ficar saudável, que por sua vez espera catálogo e perfil. Veja `docker compose logs api-gateway profile-service`. |

## Comandos úteis

```powershell
docker compose ps
docker compose logs -f api-gateway catalog-service
docker compose down
```

Para testar o Gateway e o commerce de ponta a ponta num ambiente descartável: `./scripts/test-gateway-commerce-integration.ps1 -GatewayBase http://localhost:8080 -CommerceBase http://localhost:8083`. Ele lê o token interno e o administrador do `.env` e cria contas, peças e pedidos de teste; não use em ambiente com dados reais.

`docker compose down` preserva os volumes. Os vídeos e capas enviados ao community ficam no volume `community-midia`. `docker compose down -v` apaga os bancos locais e esse volume; use esse comando somente se quiser perder esses dados. As portas HTTP e dos bancos no computador são configuráveis por `*_HOST_PORT` no `.env`; as portas publicadas dos bancos permanecem restritas a `127.0.0.1`, e dentro da rede do Compose as portas internas continuam as mesmas.

Para executar um serviço pela IDE, use a URL JDBC com `localhost` e a porta do banco na tabela acima, além do usuário e da senha configurada para aquele banco. Para executar dentro do Compose, as URLs JDBC e o endereço de cada serviço são configurados automaticamente pelos nomes dos containers. O Spring Boot não lê `.env` sozinho fora do Compose.

## Estado da integração

O frontend fala apenas com o Gateway, e todas as telas atuais têm endpoint: catálogo; perfil (autenticação, recuperação de senha, perfil público, conta, endereços, coletivos, configurações do ateliê e selo/curadoria); commerce (sacola, checkout e pedidos); community (perguntas, vídeos, conversas, avaliações, coleções e mediação); events (listagem, detalhe e criação). Recomendações por IA e indicadores administrativos ficam para depois.

### SMTP da recuperação de senha

O provedor é escolhido no `.env` por `PROFILE_SMTP_*` e `PROFILE_MAIL_FROM`; o `.env.example` traz os padrões locais e um exemplo para Gmail (senha de app, não a senha da conta). `PROFILE_FRONTEND_BASE_URL` precisa ser HTTPS e acessível em homologação; `http://localhost:4321` só serve no mesmo computador. Mudanças de `.env` não chegam a um container em execução: recrie só o perfil com `docker compose up -d --no-deps --build --wait profile-service`. Regras de validação e testes isolados estão no [README do Profile](../profile-service/README.md#pi-170--smtp-por-ambiente-e-validação-ponta-a-ponta).

## Storage opcional

O SeaweedFS (S3 das imagens de perfil) fica no perfil `storage` e tem README, scripts e docs proprios em [storage/](storage/README.md). Nao participa do primeiro start.
