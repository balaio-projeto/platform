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

Para preparar e iniciar automaticamente pelo PowerShell 7, na pasta `platform`:

```powershell
pwsh -File scripts/start-local.ps1
```

O comando preserva o `.env` existente, inicia o Docker Desktop se necessario,
prepara o primeiro uso com os scripts existentes, confere credenciais e bancos
legados, faz build e aguarda a saude de todos os servicos. Inclui storage quando
o `.env` habilita `MEDIA_S3_ENDPOINT`. Em instalacoes novas, gera uma senha de banco
aleatoria; volumes antigos precisam das suas credenciais existentes. Nao executa
pull, checkout ou atualizacoes de codigo. Nao remove volumes, redefine senhas ou
modifica historicos Flyway automaticamente.

Use `-NoBuild` para iniciar com as imagens existentes e `-Check` para verificacao
somente leitura. No primeiro uso, os preparadores requerem Git instalado para
conferir a protecao dos arquivos privados; nao fazem sincronizacao de branches.
Um banco com migrations legadas exige a transicao documentada abaixo uma unica
vez; bancos compativeis recebem novas migrations automaticamente pelo Flyway.

Na pasta `platform`, inicie a pilha completa com um comando:

```powershell
docker compose --profile extended up --build
```

O Compose usa senhas locais demonstrativas para os bancos e um token interno local, gera o par JWT RSA no volume do perfil e não exige `.env`, `admin.env`, chaves `.pem` nem scripts preparatórios. Não use esses defaults fora do computador de desenvolvimento. O administrador inicial não é criado sem `ADMIN_EMAIL` e `ADMIN_SENHA_INICIAL`; contas comuns podem ser cadastradas normalmente. O volume da chave privada é montado apenas no perfil; gateway e demais serviços recebem somente a chave pública gerada.

O SeaweedFS (PI-213) permanece disponível no perfil `storage`, com seu provisionamento descrito em [storage local](docs/storage-local.md); ele não participa do primeiro start nem do checkout PI-54.

Para pagar de fato no sandbox, forneça opcionalmente `MERCADOPAGO_ENVIRONMENT=sandbox`, `MERCADOPAGO_ACCESS_TOKEN`, `MERCADOPAGO_WEBHOOK_SECRET`, `MERCADOPAGO_NOTIFICATION_URL` (HTTPS público) e `FRONTEND_RETURN_URL` (HTTPS público). Sem o conjunto completo, o commerce inicia, mas `POST /api/v1/checkout` retorna 503. Configuração parcial ou de produção é recusada. Use conta de teste vendedora e compradora distintas; veja [roteiro PI-54](../commerce-service/docs/PI-54-checkout-pro-sandbox.md). Não versione valores dessas variáveis.

## Pilha completa (perfil extended)

`docker compose --profile extended up --build` inicia frontend, gateway, perfil, catálogo, commerce, community, events e seus bancos, sem SeaweedFS. O frontend encaminha o checkout e o estado de pedidos ao Gateway. As demais telas continuam conforme sua integração atual.

O perfil `storage` e o roteiro de provisionamento do SeaweedFS são independentes do primeiro start.

O perfil e o gateway recebem `AUTH_ALLOWED_ORIGINS`, com padrão `http://localhost:4321`. Se mudar `FRONTEND_HOST_PORT`, ajuste essa origem. Para HTTP local, `AUTH_COOKIE_SECURE=false`; em HTTPS, configure `true`. A chave privada JWT local fica no volume `jwt-local-private` acessível apenas ao perfil; a chave pública é publicada no volume `jwt-local-public` para os serviços validadores. O par persiste entre reinícios do Compose.

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

## Banco local com as antigas V5/V6 de mídia

Se o banco registra `V5__create_midias_perfil.sql` (checksum `584367059`) e
`V6__protect_media_cleanup.sql` (`704505435`), use
`db/migration/legacy-profile-media-v5-v6-to-current.sql` somente após backup
verificado e teste em cópia, com o Profile Service parado. Esse caso é diferente
do legado V1 descrito acima. O script recusa históricos diferentes, mantém os
checksums das migrations de mídia ao identificá-las como V7/V8 e aplica a V5
atual de correção dos slugs. A transação preserva contas, mídias e recuperações
de senha; perfis ausentes de artesãos são criados pela V5. Não execute `repair`
genérico nem apague volumes para resolver essa divergência.

## Comandos úteis

```powershell
docker compose ps
docker compose logs -f api-gateway catalog-service
docker compose down
```

`docker compose down` preserva os volumes. Os vídeos e capas enviados ao community ficam no volume `community-midia`. `docker compose down -v` apaga os bancos locais e esse volume; use esse comando somente se quiser perder esses dados. As portas HTTP e dos bancos no computador são configuráveis por `*_HOST_PORT` no `.env`; as portas publicadas dos bancos permanecem restritas a `127.0.0.1`, e dentro da rede do Compose as portas internas continuam as mesmas.

Para executar um serviço pela IDE, use a URL JDBC com `localhost` e a porta do banco na tabela acima, além do usuário e da senha configurada para aquele banco. Para executar dentro do Compose, as URLs JDBC e o endereço de cada serviço são configurados automaticamente pelos nomes dos containers. O Spring Boot não lê `.env` sozinho fora do Compose.

## Estado da integração

O frontend fala apenas com o Gateway. Catálogo, perfil (autenticação, recuperação de senha, perfil público, conta, configurações do ateliê e selo/curadoria), commerce (sacola, checkout e pedidos) e community (perguntas, vídeos, conversas, avaliações, coleções e mediação) atendem suas telas. Ainda não têm endpoint: no perfil, endereços e coletivos; no events, listagem, detalhe e criação de eventos. Essas telas exibem erro até os serviços implementarem as rotas que o Gateway já encaminha. Recomendações por IA e indicadores administrativos ficam para depois da entrega das telas atuais.

A collection Bruno está em `bruno/balaio-api`.

## Imagens de perfil — PI-214

A integracao opcional preserva o primeiro start descrito acima. Para habilitar
midia, execute scripts/prepare-local-storage.ps1 (sem substituir .env existente)
e inicie tambem --profile storage. O preparador gera pares independentes e
habilita o endpoint; somente o Profile Service recebe a credencial consumidora.
Veja [integracao PI-214](docs/pi-214-s3.md), incluindo as restricoes das migrations
legadas e os testes sem volumes persistentes. O frontend nao acessa o S3 direto.

Validacao da resolucao em 19/11/2026: Compose padrao e extended sem segredos
S3 passaram com .env.example; extended+storage passou com configuracao local.
Provisionamento novo, repetido, endpoint existente e rejeicao de pares
invalidos/duplicados passaram em fixture. Os oito arquivos originais locais
foram conferidos e permaneceram identicos. A fixture S3 isolada passou no
healthcheck, recusa sem credenciais, operacoes permitidas em profile e recusadas
em catalog/community, sem vazamento das quatro credenciais aleatorias.
A excecao ListBuckets vazio da versao 4.53 permanece documentada e aprovada.
A pilha real permaneceu com os 13 containers saudaveis sem recriacao.
