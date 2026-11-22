# Migrações de bancos locais legados

Só interessa a quem já tem um volume PostgreSQL do profile-service criado por versões antigas. Instalações novas não precisam disto: o Flyway aplica as migrations sozinho. O start-local.ps1 detecta esses históricos e se recusa a iniciar, sem alterar nada, até você seguir um dos procedimentos abaixo. Os SQL estão em db/migration/.

## Volume de perfil com a V1 antiga

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

## Volume de perfil com as antigas V5/V6 de mídia

Se o banco registra `V5__create_midias_perfil.sql` (checksum `584367059`) e
`V6__protect_media_cleanup.sql` (`704505435`), use
`db/migration/legacy-profile-media-v5-v6-to-current.sql` somente após backup
verificado e teste em cópia, com o Profile Service parado. Esse caso é diferente
do legado V1 descrito acima. O script recusa históricos diferentes, mantém os
checksums das migrations de mídia ao identificá-las como V7/V8 e aplica a V5
atual de correção dos slugs. A transação preserva contas, mídias e recuperações
de senha; perfis ausentes de artesãos são criados pela V5. Não execute `repair`
genérico nem apague volumes para resolver essa divergência.
