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
| seaweedfs | 8333 (somente loopback) | volume seaweedfs-data | Sim, requer provisionamento |

Cada serviço de negócio usa seu próprio banco e volume. O `profile-service` e o Gateway integram a pilha padrão para testes diretos das APIs; o frontend em modo Fake API pode iniciar sozinho. Os bancos dos três serviços opcionais são containers separados. O gateway recebe os endereços internos dos cinco serviços mesmo quando algum serviço opcional está parado. As rotas sem implementação no serviço de destino ainda retornarão erro.

## Primeiro uso

### Storage local (PI-213, Etapa 3)

O Compose inclui SeaweedFS 4.53 com volume proprio, elevando a pilha padrao a
**7 servicos** e o perfil `extended` a **13 servicos**. A configuracao de storage
falha de forma segura enquanto faltarem credenciais S3 ou certificados locais.
`setup-local.ps1` prepara automaticamente credenciais aleatorias e certificados
com PowerShell 7.2+, sem OpenSSL. Preserva `.env`, JWT e senhas existentes,
acrescentando somente configuracoes S3 ausentes. Configuracoes parciais ou
invalidas sao recusadas. Para preparar apenas storage em instalacao existente,
execute `./scripts/prepare-local-storage.ps1`; depois
`docker compose up -d --no-deps seaweedfs`. Consulte [storage local](docs/storage-local.md)
para testes autenticados, seguranca e recuperacao dos certificados.

Uma instalação nova precisa de um `.env` local, um par JWT e `secrets/admin.env` antes do primeiro `up`. No PowerShell 7.2 ou superior (`pwsh`), dentro de `platform`, execute:

```powershell
pwsh -NoProfile -File .\scripts\setup-local.ps1
# Edite .env: defina sua DB_PASSWORD antes do primeiro up.
# Edite secrets/admin.env: defina ADMIN_EMAIL e ADMIN_SENHA_INICIAL (12+ caracteres).
# Revise .env: SMTP, PROFILE_FRONTEND_BASE_URL, AUTH_ALLOWED_ORIGINS e portas.
docker compose up --build -d
```

Com o storage provisionado, esse comando inicia a pilha padrão com **7 containers**: frontend, gateway, catálogo e perfil com seus dois bancos, e SeaweedFS. Para iniciar também commerce, community e events com seus bancos (**13 containers ao todo**), use o [perfil `extended`](#pilha-completa-perfil-extended).

`setup-local.ps1` copia `.env.example` para `.env` apenas se não existir e deixa `DB_PASSWORD` vazia para você definir. Ele gera o token interno no `.env` novo, prepara JWT e cria `secrets/admin.env` apenas se faltar. Esse arquivo contém só `ADMIN_EMAIL=` e `ADMIN_SENHA_INICIAL=`; as explicações ficam em `secrets/admin.env.example`. Um `.env` existente não é alterado; se faltar o token interno, execute `./scripts/prepare-internal-token.ps1` separadamente. Preencha **você mesmo** as senhas do banco e do administrador antes do primeiro `up`. O Compose lê `secrets/admin.env` somente no `profile-service`; o script não define nem troca essas credenciais. A conta administradora é criada uma única vez em banco novo. Alterar `admin.env` depois não redefine uma conta existente. O diretório `secrets/` ignora os segredos reais no Git e mantém apenas o exemplo versionado. `prepare-local-jwt.ps1` gera e valida o par RSA de 3072 bits sem tocar no administrador. Se usar caminhos próprios para as chaves no `.env`, forneça ambos os arquivos antes do `up`. `DB_PASSWORD` vale para os cinco bancos, inclusive para o administrador do PostgreSQL do catálogo. Cada serviço continua com banco, usuário e volume próprios. Não versione `.env`.

`prepare-internal-token.ps1` gera `BALAIO_INTERNAL_TOKEN` aleatório no `.env` local, se o valor estiver vazio, e valida um valor já configurado. O Compose entrega o mesmo token ao catálogo, commerce e community; operações `/internal/v1/**` exigem esse segredo e não passam pelo Gateway. Os efeitos e parâmetros de cada script estão em [scripts/README.md](scripts/README.md). Não compartilhe nem versione o `.env`.

Com `--profile extended`, commerce e community usam esse token para reservar/confirmar/liberar peças únicas e entregar decisões de mediação. O checkout usa uma opção de frete demonstrativa e aguarda um evento de pagamento no endpoint interno do commerce. Não há cobrança, cotação externa ou reembolso financeiro. O roteiro manual `./scripts/test-gateway-commerce-integration.ps1` verifica checkout, disputa por peça única, replay, consultas do artesão, recusa, evento interno, mediação e cancelamento pelo Gateway. Informe `-GatewayBase` e `-CommerceBase` do ambiente isolado: o roteiro cria contas, peças e pedidos de teste.

Se você já usa este ambiente, mantenha o `.env` atual: `setup-local.ps1` não substitui esse arquivo, chaves ou `admin.env`, e um token interno não vazio também é preservado. `POSTGRES_ADMIN_PASSWORD`, `CATALOG_DB_PASSWORD` e eventuais senhas individuais continuam aceitas e têm prioridade. Se o `.env` não tiver `DB_PASSWORD`, preencha as senhas individuais exigidas pelos serviços que pretende iniciar ou defina `DB_PASSWORD` com um valor compatível com os bancos existentes. Os volumes PostgreSQL já criados conservam as senhas antigas; adicionar ou mudar `DB_PASSWORD` sozinho não troca a senha gravada neles. Não recrie os bancos para ajustar esta configuração.

## Pilha completa (perfil extended)

Com o storage provisionado, para iniciar os cinco serviços de negócio, os cinco bancos, o gateway, o frontend e o SeaweedFS, execute:

```powershell
docker compose --profile extended up --build -d
```

Inicie só um serviço adicional e seu banco:

```powershell
docker compose up --build -d commerce-service
```

Troque `commerce-service` por `community-service` ou `events-service` conforme o trabalho do dia. O Compose inicia o banco exigido pelo serviço escolhido. Depois da primeira criação, os containers aparecem no grupo `balaio-local` do Docker Desktop; ali você pode iniciar ou parar os containers individualmente. Para o serviço responder, inicie também o banco correspondente. O gateway pode continuar ligado quando um serviço opcional estiver desligado.

Abra `http://localhost:4321/search`. **Modo padrão: Fake API.** O frontend usa dados simulados embutidos para manter as telas existentes funcionais. Ele pode ser iniciado separadamente com `docker compose up --build -d frontend`, sem aguardar o Gateway ou o perfil. Ao iniciar a pilha completa, o gateway e o `profile-service` também sobem, mas o navegador não os usa nesse modo. Para chamar a API real diretamente, use o ambiente `Local` no Bruno e `http://localhost:8080/api/v1/pecas`.

Para validar a recuperação de senha com o backend real, construa o frontend com o arquivo adicional:

```powershell
docker compose -f docker-compose.yml -f docker-compose.recovery.yml up --build -d frontend
```

**Modo API real:** nessa configuração, `API_URL=http://api-gateway:8080/api/v1` é aplicado **no build e na execução** e a Fake API é desligada. O gateway precisa estar saudável. Cadastro, login, solicitação e redefinição de senha usam o `profile-service`; criação, listagem e edição de peças usam o `catalog-service`, conforme a implementação disponível nesses repositórios. `GET /artesao/me` devolve um slug provisório `artesao-<UUID>`. Outras telas ainda não estão integradas ao backend real, como `PATCH /usuario` e endereços. Para voltar ao frontend com Fake API, reconstrua a imagem com `docker compose up --build -d frontend`.

Para iniciar perfil, catálogo e gateway com JWT, o par deve estar em `secrets/jwt-private.pem` e `secrets/jwt-public.pem` ou nos caminhos indicados por `JWT_PRIVATE_KEY_FILE` e `JWT_PUBLIC_KEY_FILE` no `.env`. Mantenha a chave privada fora do Git. Compose entrega a chave privada somente ao perfil e a chave pública ao catálogo, gateway e demais serviços que validam tokens. `JWT_ISSUER` e `JWT_AUDIENCE` precisam ser iguais em todos eles.

O perfil e o gateway recebem `AUTH_ALLOWED_ORIGINS`, cujo padrão no Compose é `http://localhost:4321`. Se mudar `FRONTEND_HOST_PORT`, ajuste essa origem no `.env`. Para o HTTP local, o Compose passa `AUTH_COOKIE_SECURE=false` ao perfil para a configuração do cookie de sessão. Em HTTPS e produção, configure `AUTH_COOKIE_SECURE=true`, mantenha `HttpOnly` e `SameSite` apropriados e restrinja `AUTH_ALLOWED_ORIGINS` às origens confiáveis. O efeito do parâmetro de cookie depende da implementação do `profile-service` utilizada.

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
