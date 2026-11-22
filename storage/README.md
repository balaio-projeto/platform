# Storage local (SeaweedFS)

Serviço S3 opcional que guarda as imagens de perfil dos artesãos. Está definido em [docker-compose.storage.yml](../docker-compose.storage.yml), no perfil `storage`, e não participa do primeiro start. Os comandos abaixo rodam a partir da pasta `platform`, no PowerShell 7.2+. Detalhes do provisionamento, do TLS e dos backups estão em [docs/storage-local.md](docs/storage-local.md).

## Como habilitar

```powershell
$env:COMPOSE_FILE = 'docker-compose.yml;docker-compose.storage.yml'   # vale só para esta sessão do PowerShell
./storage/scripts/prepare-local-storage.ps1
docker compose --profile extended --profile storage up -d --build --wait
```

`docker-compose.storage.yml` é um complemento: define o `seaweedfs` e entrega `MEDIA_S3_*` ao `profile-service`, e por isso precisa ser carregado junto do principal. Sem ele, o Profile sobe sem S3 mesmo que o `.env` tenha o endpoint. Em vez da variável, dá para usar `docker compose -f docker-compose.yml -f docker-compose.storage.yml ...` em cada comando. O `start-local.ps1` e os scripts de teste já fazem isso sozinhos.

O preparador exige o `.env` (`start-local.ps1` ou cópia do `.env.example`) e acrescenta a ele só o que falta:

- dois pares de credenciais aleatórios e independentes (administrador e Profile Service);
- `S3_HOST_PORT` e `MEDIA_S3_ENDPOINT=http://seaweedfs:8333`;
- certificados RSA 3072 em `secrets/seaweedfs/` e a chave da CA em `secrets/seaweedfs-ca/`.

Valores válidos são preservados. Configuração parcial, par duplicado ou certificado perto do vencimento é recusado sem sobrescrever nada. Usa só PowerShell, .NET e Git (sem OpenSSL), e exige que os caminhos estejam fora do controle do Git.

Mudanças de variável só chegam a um container existente se ele for recriado:

```powershell
docker compose --profile extended --profile storage up -d --no-deps --build --wait seaweedfs profile-service
```

## Acesso do Profile Service

O servidor tem duas identidades estáticas: `balaio-local-admin` e `balaio-profile-service`. A segunda é ligada, por `policyNames`, à política [profile-s3-policy.json](profile-s3-policy.json):

- permite `GetObject`, `PutObject` e `DeleteObject` apenas em `balaio-media/profile/*`;
- nega `ListAllMyBuckets`;
- não usa as permissões legadas `Read`, `Write`, `Admin` ou `List`.

O Profile Service recebe `MEDIA_S3_ENDPOINT`, `MEDIA_S3_REGION`, `MEDIA_S3_BUCKET` e o par `MEDIA_S3_ACCESS_KEY_ID` / `MEDIA_S3_SECRET_ACCESS_KEY`. Gateway, frontend e os demais serviços não recebem esse par nem as credenciais do administrador. O frontend nunca acessa o S3 direto. Se o endpoint estiver definido sem o par completo, o Profile se recusa a iniciar.

`start.sh` monta a configuração de identidades em `/tmp` (tmpfs, modo 0600) e remove os pares do ambiente do processo `weed`. Sem credenciais de administrador válidas, o SeaweedFS não inicia. A identidade do Profile cobre todo `profile/*`: separar os arquivos de cada usuário é responsabilidade do backend.

### Limitação conhecida

Na versão 4.53, `ListBuckets` responde HTTP 200 com lista vazia, mesmo com o Deny explícito, porque o SeaweedFS decide a visibilidade dentro do handler. Isso foi aceito e é verificado pelo teste automatizado. Se for obrigatório um 403, é preciso investigar uma versão corrigida ou um ponto de acesso que imponha a restrição, com nova prova isolada.

Referências da versão: [schema de identidades](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/pb/iam.proto), [autorização e ListBuckets](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/s3api/auth_credentials.go), [handler de ListBuckets](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/s3api/s3api_bucket_handlers.go).

## Testes

| Script | O que verifica | Precisa da pilha no ar |
| --- | --- | --- |
| `test-storage-provisioning.ps1` | Geração, idempotência e recusa de pares inválidos, em fixture descartável | Não |
| `test-profile-storage-isolated.ps1` | Política do Profile em container sem rede, sem portas e com dados em tmpfs | Não (exige `secrets/seaweedfs/` já preparado) |
| `test-local-storage.ps1` | Host, Docker, bucket privado, mTLS e logs; `-IncludeSpecialCharacterTest` cria uma fixture isolada para credenciais com caracteres especiais | Sim (`seaweedfs`) |
| `test-profile-storage.ps1` | Acesso por prefixo na rede Docker, variáveis do container e logs | Sim |
| `test-storage-recovery.ps1 -AllowStorageInterruption` | Persistência após reinício, backup com parada limpa e restauração em volume e projeto novos | Sim |

Os scripts ficam em `storage/scripts/`. Nenhum imprime segredos e todos limpam só o que criaram. Os que usam containers reais respeitam `COMPOSE_FILE` e `COMPOSE_PROJECT_NAME`.

## Backup e restauração

`test-storage-recovery.ps1` guarda um snapshot em `backups/seaweedfs-<data>-<id>/` e `restore-local-storage.ps1 -BackupDirectory <snapshot>` o restaura sempre em outro volume e projeto, sem ler o `.env` principal. Nenhum dos dois sobrescreve volume ou backup existente, nem serve como script de limpeza.

**Limite de segurança atual:** os snapshots contêm credenciais S3 e chaves privadas sem criptografia, e o restaurador executa scripts e um template Compose vindos do snapshot. Aceite só cópias locais confiáveis, nunca arquivos de terceiros, e não grave `backups/` em pasta sincronizada (como o OneDrive); veja [segurança dos backups](docs/storage-local.md#segurança-dos-backups).

## Bancos com migrations antigas de mídia

O storage não altera o banco do Profile. Se o seu volume tem as antigas V5/V6 de mídia, siga antes a transição descrita no [guia de migrações legadas](../docs/migracoes-legadas.md).
