# Platform Balaio

Ambiente de desenvolvimento local do Balaio. Cada aplicação tem seu repositório e sua imagem. O Compose monta a rede, os bancos PostgreSQL e os containers que você escolher iniciar.

## Repositórios lado a lado

```text
Repo/
├── Balaio/Frontend/
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

Cada serviço de negócio usa seu próprio banco e volume. O `profile-service` e o Gateway integram a pilha padrão para testes diretos das APIs; o frontend em modo Fake API pode iniciar sozinho. Os bancos dos três serviços opcionais são containers separados. O gateway recebe os endereços internos dos cinco serviços mesmo quando algum serviço opcional está parado. As rotas sem implementação no serviço de destino ainda retornarão erro.

## Primeiro uso

Uma instalação nova precisa de um `.env` local com senhas próprias para os bancos e do par JWT antes do primeiro `up`. Copie `.env.example` para `.env`, defina `DB_PASSWORD` com uma senha forte e exclusiva para este ambiente e, se necessário, configure credenciais individuais. O Compose falha ao iniciar se não houver uma senha configurada. No PowerShell, dentro de `platform`, execute:

```powershell
Copy-Item .env.example .env
# Edite .env e defina DB_PASSWORD com uma senha local forte e exclusiva.
./scripts/prepare-local-jwt.ps1
./scripts/prepare-internal-token.ps1
docker compose up --build -d
```

O script gera localmente as duas chaves RSA de 3072 bits se não existirem, valida o par e não substitui chaves existentes. Também cria `secrets/admin.env` com uma senha aleatória para o administrador inicial, exigida pelo perfil na primeira inicialização. O diretório `secrets/` é ignorado pelo Git; guarde a senha desse arquivo para entrar como administrador. Se usar caminhos próprios para as chaves no `.env`, forneça ambos os arquivos antes do `up`. `DB_PASSWORD` vale para os cinco bancos, inclusive para o administrador do PostgreSQL do catálogo. Cada serviço continua com banco, usuário e volume próprios. Não versione `.env`.

`prepare-internal-token.ps1` gera `BALAIO_INTERNAL_TOKEN` aleatório no `.env` local, se o valor estiver vazio, e valida um valor já configurado. O Compose entrega o mesmo token ao catálogo, commerce e community; operações `/internal/v1/**` exigem esse segredo e não passam pelo Gateway. Não compartilhe nem versione o `.env`.

Com `--profile extended`, commerce e community usam esse token para reservar/confirmar/liberar peças únicas e entregar decisões de mediação. Para iniciar o commerce com PI-54, configure no `.env` local `MERCADOPAGO_ENVIRONMENT=sandbox`, token e segredo webhook de uma aplicação de teste, além das URLs públicas HTTPS de webhook e retorno. O serviço recusa inicialização sem essa configuração. O token e o segredo não são entregues ao frontend. O roteiro legado `./scripts/test-pi190-gateway.ps1` usa o simulador de pagamento removido no PI-54 e não valida mais o checkout atual; use o roteiro sandbox de `commerce-service/docs/PI-54-checkout-pro-sandbox.md`.

Se você já usa este ambiente, mantenha o `.env` atual: `POSTGRES_ADMIN_PASSWORD`, `CATALOG_DB_PASSWORD` e eventuais senhas individuais continuam aceitas e têm prioridade. Os volumes PostgreSQL já criados conservam as senhas antigas; adicionar ou mudar `DB_PASSWORD` sozinho não troca a senha gravada neles. Assim, o ambiente existente continua funcionando sem recriar bancos.

Inicie os cinco serviços de negócio, os bancos, o gateway e o frontend:

```powershell
docker compose --profile extended up --build -d
```

Inicie só um serviço adicional e seu banco:

```powershell
docker compose up --build -d commerce-service
```

Troque `commerce-service` por `community-service` ou `events-service` conforme o trabalho do dia. O Compose inicia o banco exigido pelo serviço escolhido. Depois da primeira criação, os containers aparecem no grupo `balaio-local` do Docker Desktop; ali você pode iniciar ou parar os containers individualmente. Para o serviço responder, inicie também o banco correspondente. O gateway pode continuar ligado quando um serviço opcional estiver desligado.

Abra `http://localhost:4321/search`. No Compose padrão, o frontend usa a Fake API embutida para manter as telas existentes funcionais. Ele pode ser iniciado separadamente com `docker compose up --build -d frontend`, sem aguardar o Gateway ou o perfil. Ao iniciar a pilha completa, o gateway e o `profile-service` também sobem, mas o navegador não os usa nesse modo. No Bruno, use o ambiente `Local` e `http://localhost:8080/api/v1/pecas`.

Para validar a recuperação de senha com o backend real, construa o frontend com o arquivo adicional:

```powershell
docker compose -f docker-compose.yml -f docker-compose.recovery.yml up --build -d frontend
```

Nesse modo, `API_URL=http://api-gateway:8080/api/v1` é aplicado **no build e na execução** e a Fake API é desligada. Cadastro, login, solicitação e redefinição de senha usam o `profile-service`; criação, listagem e edição de peças usam o `catalog-service`. `GET /artesao/me` devolve um slug provisório `artesao-<UUID>`. Outras telas ainda não estão integradas ao backend real, como `PATCH /usuario` e endereços. Para voltar ao frontend completo com Fake API, reconstrua a imagem com `docker compose up --build -d frontend`.

Para iniciar perfil e catálogo com JWT, o par deve estar em `secrets/jwt-private.pem` e `secrets/jwt-public.pem` ou nos caminhos indicados por `JWT_PRIVATE_KEY_FILE` e `JWT_PUBLIC_KEY_FILE` no `.env`. Mantenha a chave privada fora do Git. Compose entrega apenas a chave pública ao catálogo; `JWT_ISSUER` e `JWT_AUDIENCE` precisam ser iguais nos dois serviços.

O perfil também exige `AUTH_ALLOWED_ORIGINS`, cujo padrão no Compose é `http://localhost:4321`. Se mudar `FRONTEND_HOST_PORT`, ajuste essa origem no `.env`.

### Volume de perfil legado

O volume `balaio-local` criado pela migration `V1__accounts_and_password_recovery.sql` (checksum `449745879`) não valida contra a V1 atual. O procedimento de transição para esse esquema específico está em `db/migration/legacy-profile-v1-to-pi168.sql`. Ele verifica histórico e contas antes de alterar, preserva as três tabelas antigas com prefixo `legacy_`, copia as contas com os mesmos UUIDs e prefixa os hashes bcrypt. Só então reconcilia o registro V1 do Flyway; V2 e V3 são aplicadas ao iniciar o perfil. Sessões e links de recuperação antigos ficam arquivados e deixam de funcionar: entre novamente ou solicite nova recuperação.

Antes da execução, pare o `profile-service`, crie e confira um backup do banco e restaure-o em um projeto Compose separado para testar o SQL. Exemplo no PowerShell, dentro de `platform`:

```powershell
docker compose stop profile-service
New-Item -ItemType Directory -Force backups | Out-Null
docker exec balaio-local-profile-db-1 pg_dump -U balaio_profile_app -d balaio_profile -Fc -f /tmp/profile-before-pi168.dump
docker cp balaio-local-profile-db-1:/tmp/profile-before-pi168.dump backups/profile-before-pi168.dump
docker exec balaio-local-profile-db-1 pg_restore -l /tmp/profile-before-pi168.dump
$env:PROFILE_DB_HOST_PORT='45435'
docker compose -p balaio-legacy-qa up -d --wait profile-db
docker cp backups/profile-before-pi168.dump balaio-legacy-qa-profile-db-1:/tmp/profile-before-pi168.dump
docker exec balaio-legacy-qa-profile-db-1 pg_restore -U balaio_profile_app -d balaio_profile --exit-on-error /tmp/profile-before-pi168.dump
docker cp db/migration/legacy-profile-v1-to-pi168.sql balaio-legacy-qa-profile-db-1:/tmp/migrate.sql
docker exec balaio-legacy-qa-profile-db-1 psql -U balaio_profile_app -d balaio_profile -f /tmp/migrate.sql
```

Depois de validar a cópia com o perfil atual, execute o mesmo SQL no volume original e confira os históricos V1–V3 e as contagens preservadas:

```powershell
docker cp db/migration/legacy-profile-v1-to-pi168.sql balaio-local-profile-db-1:/tmp/migrate.sql
docker exec balaio-local-profile-db-1 psql -U balaio_profile_app -d balaio_profile -f /tmp/migrate.sql
docker compose up -d --wait profile-service
docker exec balaio-local-profile-db-1 psql -U balaio_profile_app -d balaio_profile -c 'SELECT version, checksum, success FROM flyway_schema_history ORDER BY installed_rank'
```

`backups/` é ignorado pelo Git. O SQL aborta se o volume já foi migrado ou se o histórico/dados diferem do esquema examinado; nesse caso, não use `repair` automaticamente.

## Comandos úteis

```powershell
docker compose ps
docker compose logs -f api-gateway catalog-service
docker compose down
```

`docker compose down` preserva os volumes. `docker compose down -v` apaga os bancos locais do Compose; use esse comando somente se quiser perder esses dados. As portas HTTP e dos bancos no computador são configuráveis por `*_HOST_PORT` no `.env`; as portas publicadas dos bancos permanecem restritas a `127.0.0.1`, e dentro da rede do Compose as portas internas continuam as mesmas.

Para executar um serviço pela IDE, use a URL JDBC com `localhost` e a porta do banco na tabela acima, além do usuário e da senha configurada para aquele banco. Para executar dentro do Compose, as URLs JDBC e o endereço de cada serviço são configurados automaticamente pelos nomes dos containers. O Spring Boot não lê `.env` sozinho fora do Compose.

## Estado da integração

O catálogo implementa a listagem de peças, e o serviço de perfil implementa cadastro, login e recuperação de senha. A integração do frontend real está limitada a esse fluxo de autenticação; as demais telas dependem da Fake API no modo padrão. Os demais serviços ainda precisam implementar seus endpoints. O gateway já encaminha os caminhos da Fake API para seus donos; `GET /api/v1/estado` depende de definir como compor dados de três serviços. Recomendações por IA e indicadores administrativos ficam para depois da entrega das telas atuais.

A collection Bruno está em `bruno/balaio-api`.
