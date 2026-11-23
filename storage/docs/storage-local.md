# Storage local (SeaweedFS): operação e segurança

Guia operacional do storage S3 local, para Windows/PowerShell. Para habilitar o
storage e ver o acesso do Profile Service, comece pelo [README do storage](../README.md).
**Os backups não são criptografados**: leia [Segurança dos backups](#segurança-dos-backups)
antes de gerar uma cópia.

## Preparar e iniciar

Requisitos: Docker Desktop/Compose, Git e PowerShell 7.2+ (`pwsh`). Certificados
usam somente o .NET do PowerShell, sem OpenSSL ou PKI externa. O provisionamento
de permissões desta entrega é voltado ao Windows.

Na pasta `platform`, o `.env` precisa existir (`start-local.ps1` ou cópia do
`.env.example`). O storage está em `docker-compose.storage.yml`, que deve ser
carregado junto do principal (veja o [README do storage](../README.md#como-habilitar)).
Nos comandos deste guia, assume-se a variável abaixo na sessão atual. Pilha
completa com storage:

```powershell
$env:COMPOSE_FILE = 'docker-compose.yml;docker-compose.storage.yml'
./storage/scripts/prepare-local-storage.ps1
docker compose --profile extended --profile storage up --build -d
```

Em ambiente já em execução, preparar e subir somente o storage:

```powershell
./storage/scripts/prepare-local-storage.ps1
docker compose --profile storage up -d --no-deps seaweedfs
docker compose ps seaweedfs
./storage/scripts/test-local-storage.ps1
```

O storage pertence ao perfil `storage` e não adiciona dependências aos outros
serviços. O preparador não inicia containers nem modifica bancos, e preserva o
`.env`, o JWT, o SMTP, o token interno e as senhas existentes. Não substitua o
`.env`. Sem credenciais, o seaweedfs recusa iniciar: execute o preparador antes,
sem desabilitar a autenticação.

## Imagem e dados

- Imagem `chrislusf/seaweedfs:4.53`, Apache-2.0.
- Digest `sha256:ccad23e18639c8b98cee17e7100b95830a06077b56d8e5b006d6dcf8ec5e94a0`.
- Binário verificado: `version 30GB 4.53 4ab66fb76 linux amd64`.
- `weed mini -dir=/data`; reinício `unless-stopped`.
- Volume `balaio-local_seaweedfs-data:/data`, incluindo objetos, metadados do
  filer (`/data/filerldb2`), configurações internas e estado administrativo.
- `/tmp` em tmpfs: configuração S3 temporária não pertence ao volume de dados.

O entrypoint oficial ajusta ownership e executa como usuário `seaweed`. Nenhum
volume PostgreSQL é alterado. Não remover volumes para limpeza.

## Provisionamento idempotente

`prepare-local-storage.ps1` aceita `-EnvFile` e `-SecretsDirectory`; caminhos devem
estar ignorados e não rastreados pelo Git. Caminhos alternativos de certificados
exigem alinhar os mounts do Compose. Configurações parciais exigem recuperação
explícita; evitar edições concorrentes durante o setup.

Quando ambos os valores faltam ou estão vazios, gera `S3_ACCESS_KEY_ID` com
16 bytes aleatórios (128 bits) e `S3_SECRET_ACCESS_KEY` com 32 bytes (256 bits),
em hexadecimal. Acrescenta `S3_HOST_PORT=8333` se ausente/vazia. Um par existente
válido permanece idêntico. Apenas uma credencial preenchida, duplicatas, valores
inválidos e portas inválidas provocam erro, sem substituir valores inválidos.

Access key: 20–128 caracteres alfanuméricos, `_` ou `-`. Secret: 40–256 caracteres
ASCII imprimíveis. No `.env`, valores com `$`, `#`, espacos ou aspas duplas usam
aspas simples literais; apostrofo interno usa `\'`. Prefira o hexadecimal gerado.
O healthcheck suporta caracteres especiais sem interpretar o segredo como código.

Não executar `docker compose config` sem `--quiet` ou filtragem: a configuração
resolvida contém segredos. Não colocar valores reais em comandos, tickets ou Git.

## Certificados e recuperação

Quando nenhum arquivo existe, gera RSA 3072/SHA-256:

- `secrets/seaweedfs/ca.crt`: CA pública, validade de dez anos.
- `secrets/seaweedfs/tls.crt`: certificado de dois anos; CN `seaweedfs-internal`,
  SAN DNS `seaweedfs`/`localhost` e IP `127.0.0.1`, EKUs serverAuth/clientAuth.
- `secrets/seaweedfs/tls.key`: chave privada interna.
- `secrets/seaweedfs-ca/ca.key`: chave privada CA, nunca montada no container.

Diretórios novos recebem ACLs limitadas ao usuário Windows, SYSTEM e
Administradores. Docker Desktop deve usar o contexto desse usuário. Somente o
storage recebe `secrets/seaweedfs/`, read-only. Microsservicos usarão S3 e não
devem receber certificados/chaves de cliente TLS.

O preparador valida cadeia, validade (margem de sete dias), identidade, SAN,
EKUs e correspondência das chaves. Preserva certificados válidos byte a byte;
recusa conjuntos parciais/corrompidos/vencidos, sem rotação silenciosa. Não altera
a trust store do Windows. Arquivos sensíveis ficam fora do Git.

Preservar `.env`, os dois diretórios de certificados/CA e o volume de dados.
Para recuperar configuração: parar somente `seaweedfs`, restaurar o conjunto
completo correspondente de uma cópia protegida, executar o preparador para
validar e `up -d --no-deps seaweedfs`. Não remover volumes nem trocar senhas de
bancos/JWT. Certificados internos não são chaves de criptografia dos objetos.

Sem cópia de um conjunto incompleto/vencido, preservar os arquivos antigos em
local protegido e realizar regeneração/rotação explícita com storage parado e
teste isolado. Não existe reset automático nesta etapa. Novas credenciais S3 não
revogam necessariamente identidades antigas no IAM persistido: conferir/revogar
explicitamente ao rotacionar, sem apagar dados.

## Rede e proteções

S3 interno `http://seaweedfs:8333`; host `http://localhost:8333`, publicado somente
em `127.0.0.1:${S3_HOST_PORT:-8333}`. HTTP é adequado somente a rede Docker local
confiável; esta não é configuração de produção.

O mini compartilha `-ip.bind`; ausência de portas publicadas não protege a rede.
Por isso mantemos mTLS nas interfaces auxiliares:

- Master HTTPS 9333 / gRPC 19333.
- Volume HTTPS 9340 / gRPC 19340.
- Filer HTTPS 8888 / gRPC 18888; listagem/metadados de diretórios desativados.
- S3 HTTP 8333 exige SigV4; gRPC 18333 exige mTLS.
- Clientes internos de administração/worker também usam o certificado mTLS.
- WebDAV, Iceberg, Lance e portas administrativas legadas desativados.
- Administração HTTP 12535 e controle gRPC 22535 somente em loopback dentro do
  container, sem publicação e inacessíveis pela rede Docker.

Na versão 4.53, `admin.ui=false` impede o listener esperado pelo próprio readiness
e provoca encerramento após dois minutos. Mantemos a UI em loopback com o padrão
seguro da versão, sem `allowInsecureBind`. Não configurar senha/https.admin nem
alterar bind administrativo sem reavaliar exposição: isso pode habilitar bind
externo nessa versão.

O fallback AWS por ambiente registra a access key no log nativo. `start.sh`
valida credenciais, constrói JSON escapado em tmpfs (0600/usuário seaweed), remove
as variáveis AWS do processo weed e passa `-s3.config` antes dos outros argumentos.
Docker mantém as variáveis para healthchecks; valores não entram em argv.
Credenciais/certificados ausentes e argumentos posicionais inválidos são
recusados antes de iniciar weed. Não há fallback anônimo.

O administrador do host/Docker ainda pode inspecionar segredos. O aviso nativo
de IAM gRPC sem JWT não significa porta pública: transporte Filer exige mTLS e
foi testado sem certificado de cliente.

## Bucket e permissões

Bucket único **`balaio-media`**, criado idempotentemente e privado. Os objetos
usam os prefixos `profile/`, `catalog/` e `community/`; os testes usam somente
`diagnostics/pi213-<identificador>.txt`. Prefixos organizam dados, sem substituir
autorização.

Há três identidades: `balaio-local-admin` (ação `Admin`, exclusiva do
provisionamento e dos testes locais, nunca entregue ao frontend nem aos serviços),
`balaio-profile-service`, limitada a `profile/*`, e `balaio-catalog`, limitada a
`catalog/*` (ver o [README do storage](../README.md#acesso-do-catalog-service-pi-175)).
Community ainda não usa o storage; quando usar, precisa da própria identidade com
permissões mínimas no seu prefixo. Não há política anônima nem objetos públicos.

### Identidade do catálogo (PI-175 / PI-254)

`balaio-catalog` é ligada por `policyNames` à política
[catalog-s3-policy.json](../catalog-s3-policy.json): `GetObject`, `PutObject` e
`DeleteObject` (o equivalente a Read/Write) apenas em `balaio-media/catalog/*`, e
`ListAllMyBuckets` negado. Não recebe `Admin`, `List`, ACL nem outros prefixos. O
bucket continua privado: o navegador lê as fotos de peça publicada por
`GET /api/v1/arquivos/pecas/{nome}` no gateway, e o catalog-service busca o objeto
com a própria credencial. O PostgreSQL do catálogo guarda só metadados, ordem e a
chave `catalog/<slug>/<id>.<ext>`.

O preparador gera `CATALOG_S3_ACCESS_KEY_ID` e `CATALOG_S3_SECRET_ACCESS_KEY`
(128/256 bits aleatórios) no `.env` ignorado pelo Git quando o par não existe,
preserva pares existentes e recusa par parcial ou reutilizado do administrador ou
do Profile. `start-local.ps1` executa o preparador sempre que o par do catálogo
falta, inclusive em instalações que já tinham o storage do Profile.
`docker-compose.storage.yml` entrega o par só ao `seaweedfs` e ao
`catalog-service`, com `CATALOG_S3_ENABLED=true`, endpoint
`http://seaweedfs:8333`, região `us-east-1` e bucket `balaio-media`. Para voltar
ao modo sem S3 no catálogo, defina `CATALOG_S3_ENABLED=false` no `.env`.

Para aplicar em uma pilha já rodando, sem apagar volumes:

```powershell
./storage/scripts/prepare-local-storage.ps1
docker compose -f docker-compose.yml -f docker-compose.storage.yml --profile extended --profile storage up -d --build --wait seaweedfs catalog-service
./storage/scripts/test-catalog-storage.ps1
```

`test-catalog-storage.ps1` confere que o par chegou só ao storage e ao catálogo,
que o container do catálogo recebeu a configuração e roda
`storage/test-catalog-access.sh` na rede do Compose: PUT/GET/HEAD/DELETE em
`catalog/*` aprovados; ACL, `profile/*`, `community/*`, prefixo semelhante,
ListObjects, criação de bucket e GET anônimo recusados (403); ListBuckets segue a
exceção conhecida do SeaweedFS 4.53 (200 com lista vazia). Por fim verifica que
nenhuma credencial aparece nos logs do storage e do catálogo. Os diagnósticos
criam e removem somente objetos com identificador exclusivo.

Validação em 22/11/2026 na pilha local: peça criada pelo gateway com duas fotos em
data URI (como o formulário do front envia), objetos gravados em `catalog/`,
download por `GET /api/v1/arquivos/pecas/{nome}` com HTTP 200 e bytes idênticos,
inclusive após `docker compose restart catalog-service` e após reiniciar o
`seaweedfs`. Na edição, a foto removida passou a responder 404 e a nova foto 200,
na ordem enviada.

Fluxo: Frontend -> API Gateway -> microsservico -> SeaweedFS. O navegador não envia
arquivos ao storage nem recebe nomes DNS do Docker.

## Testar e diagnosticar

```powershell
docker compose ps seaweedfs
docker compose exec -T seaweedfs /bin/sh /opt/balaio/storage/healthcheck.sh
./storage/scripts/test-local-storage.ps1
./storage/scripts/test-local-storage.ps1 -IncludeSpecialCharacterTest
```

O roteiro usa SigV4 via HttpClient/.NET no host, sem AWS CLI. Testa ListBuckets,
HeadBucket, upload/download com hashes idênticos e recusa anônima. Remove somente
o objeto diagnóstico único que acabou de criar. Um cliente Docker separado recebe
somente CA pública, sem chave/certificado de cliente, para testar as interfaces.

CT-14 opcional: container sem rede, sem portas publicadas, `/data` e `/tmp` em
tmpfs, sem volume persistente. A fixture rotulada é removida ao concluir. Testa
autenticação real com espacos, aspas, barra invertida, `$`, `#`, `+`, `/`, `=`, `:`
e ausência dos valores nos logs.

Healthcheck: HeadBucket assinado precisa funcionar e ListBuckets anônimo retornar
403. Credenciais escapadas vão por stdin ao curl; saida descartada. Não substitui
teste completo de persistência/backup.

Falha de autenticação: executar preparador para validar, conferir par S3 sem
imprimi-lo, bucket e relógio. Recriar somente storage após mudar variáveis;
restart não atualiza ambiente. Não desabilitar assinatura ou mTLS. Probes HTTP
nativos contra HTTPS podem gerar mensagens de handshake no startup; healthcheck
S3 e os testes devem passar. Inspecionar logs somente com filtragem; o roteiro
confere em memória que nenhum dos dois valores S3 reais aparece nos logs atuais.

## Operação segura: reinício e recriação

Conferir o Engine antes de qualquer operação. Se indisponível, interromper o
roteiro e registrar bloqueio; não alterar Compose, redes ou Docker para contornar.

```powershell
docker version --format '{{.Server.Version}}'
docker compose --profile extended config --quiet
docker compose ps seaweedfs
docker compose restart -t 60 seaweedfs
docker compose exec -T seaweedfs /bin/sh /opt/balaio/storage/healthcheck.sh
```

Aguardar healthy antes de usar. Para recriar somente o container, preservando o
volume nomeado e sem reconstruir ou reiniciar os demais:

```powershell
docker compose up -d --no-deps --force-recreate seaweedfs
docker compose ps seaweedfs
```

Recriação é necessária quando mudam variáveis; restart não atualiza ambiente.
Não executar down com remoção de volumes, volume prune ou volume rm. Nenhum
procedimento abaixo remove volumes, nem mesmo os volumes isolados de validação.

## Backup consistente e verificável

Para esta instalação single-node, foi adotada cópia fria de **todo** `/data`,
com SeaweedFS parado. Copiar somente arquivos de volume sem os metadados do
filer não é suficiente. A documentação oficial também exige coordenar dados e
metadados e recomenda a mesma versão na recuperação:
[Data Backup](https://github.com/seaweedfs/seaweedfs/wiki/Data-Backup).

O roteiro exige interrupção local explícita do storage. **Não gere backups em
pasta sincronizada** (ver [Segurança dos backups](#segurança-dos-backups)). Ele não
criptografa o snapshot nem permite escolher um destino fora do repositório:

```powershell
./storage/scripts/test-storage-recovery.ps1 -AllowStorageInterruption
```

Esse comando é um **ensaio de recuperação completo**, não um simples smoke test:
envia um objeto único, testa restart/recriação, faz backup e restaura em outro
projeto. Exige a pilha em execução e deve ser usado em uma
janela em que o storage possa ficar temporariamente indisponível.

O procedimento implementado no roteiro e:

1. Registrar IDs/StartedAt dos outros 12 containers e hashes dos arquivos
   protegidos, sem registrar seus valores.
2. Criar destino único `backups/seaweedfs-<UTC>-<id>/`, recusando destino existente.
   Aplicar ACL somente para usuário Windows, SYSTEM e Administradores.
3. Parar somente `seaweedfs` com timeout de 60 segundos; exigir processo parado
   com exit code zero. Não declarar backup consistente após parada forcada.
4. Montar o volume original **read-only** em helper sem rede, usando a mesma
   imagem fixada. Gerar `data.tar.gz` e `volume-files.sha256` para todos os arquivos.
5. Guardar versão/digest e configuração no template Compose de restauração, copiar
   scripts, certificados e chave CA e guardar somente as credenciais S3 necessárias.
   Senhas PostgreSQL, JWT e credenciais do administrador Balaio não são copiadas.
6. Validar leitura do tar e calcular SHA-256 do arquivo. Reiniciar somente o storage
   principal em bloco finally, inclusive se a cópia falhar; aguardar healthy.
7. Restaurar e verificar o snapshot isoladamente antes de considerar a prova aprovada.

Conteúdo do snapshot:

- `data.tar.gz`: dados, índices, metadados do filer, estado interno e chaves internas.
- `volume-files.sha256`: inventário de integridade antes da inicialização restaurada.
- `config/storage/`: scripts e configuração de segurança da versão testada.
- `config/secrets/seaweedfs/` e `config/secrets/seaweedfs-ca/`: material TLS original.
- `config/s3-credentials.json`: credenciais recuperáveis; **arquivo sensível**.
- `restore.compose.json`: imagem/digest, argumentos, healthcheck e mounts do snapshot;
  usa placeholders de ambiente, não valores literais das credenciais.
- `manifest.json`: resultados, hash do tar, hash do objeto e hashes da configuração.

O snapshot não inclui dados temporários de `/tmp`: a configuração S3 efêmera e
reconstruida com as credenciais recuperadas. Arquivos LevelDB mudam normalmente
quando o servidor abre; verificar o inventário antes da primeira inicialização,
não exigir os mesmos hashes dos arquivos internos após o servidor funcionar.

Backups são ignorados pelo Git e contém segredos em texto claro, protegidos por
ACL, **sem criptografia do arquivo**. Não publicar nem anexar a tickets. O workspace
atual está em OneDrive; confirmar a política de sincronização antes de manter
cópias sensíveis ali e guardar cópia externa protegida/criptografada para sobreviver
a perda do host. ACL e checksum não substituem criptografia nem backup fora do host.

Este procedimento garante consistência do SeaweedFS single-node parado. Ainda
não constitui backup transacional dos futuros metadados de mídia nos bancos dos
microsservicos: esse alinhamento sera necessário quando os uploads forem integrados.

## Restaurar um backup existente, sem acessar a instalação principal

```powershell
./storage/scripts/restore-local-storage.ps1 -BackupDirectory '.\backups\<snapshot>'
```

O restaurador usa `--env-file` vazio explícito para impedir a descoberta automática
do `.env` principal pelo Compose. Não chama o setup principal e não para
o Balaio. O backup original não e sobrescrito. Ele:

1. Exige manifesto de ensaio concluído, confere o SHA-256 do tar e os hashes de
   configurações/certificados e exige tag 4.53 com digest SHA-256 informado no
   template. O script ainda não compara esse digest com uma lista de aprovados.
2. Cria um volume com nome único; recusa volume existente e exige destino vazio
   antes de extrair. Não recebe um parâmetro que permita apontar para o volume original.
3. Extrai com helper sem rede e verifica todos os arquivos antes de iniciar o servidor.
4. Cria Compose de sessão em `backups/restore-session-<id>/`, ajustando caminhos
   para o snapshot selecionado. Não altera o template original.
5. Sobe somente SeaweedFS em projeto/rede exclusivos; publica S3 em porta aleatória
   de `127.0.0.1`, usando certificados e credenciais somente do snapshot.
6. Aguarda healthy, recupera o objeto diagnóstico, compara SHA-256 e exige 403
   para leitura anônima. Verifica logs sem exibir credenciais.
7. Para a restauração, preservando container/rede/volume para revisão; grava
   resultado não sensível em `restore-result.json` da sessão.

O ensaio completo também compara Content-Type, Content-Length, ETag,
Last-Modified e os metadados personalizados `pi213-run`/`sha256` e testa a
segurança das interfaces auxiliares a partir da rede isolada.

Nunca usar estes roteiros para sobrescrever a instalação principal. Uma futura
promoção da recuperação exige janela e revisão separadas. Manter o conjunto TLS,
as credenciais e a versão correspondentes; não executar geração automática para
"consertar" um snapshot incompleto. O checksum detecta corrupção em relação ao
manifesto confiável; não autentica um backup fornecido por terceiros.

## Segurança dos backups

- Os snapshots guardam em texto claro as credenciais S3, a chave TLS, a chave privada da CA e o `/data`, que também pode conter estado sensível. Proteger só o `s3-credentials.json` não basta.
- A ACL limita o acesso local, mas não impede que um cliente de sincronização (OneDrive e similares) do mesmo usuário envie os arquivos. Mantenha `backups/` fora de pastas sincronizadas.
- `.gitignore`, SHA-256 e `tar.gz` não criptografam nem autenticam a origem. Os scripts ainda não criptografam o snapshot; uma opção é empacotá-lo com [age](https://github.com/FiloSottile/age) antes de copiá-lo para fora do host.
- Criptografar uma cópia nova não elimina a exposição de cópias antigas. Se um snapshot foi sincronizado por engano, rotacione as credenciais S3 e a CA.

## Limitações conhecidas dos scripts

- **O restaurador confia no snapshot.** Ele reutiliza os scripts e o Compose guardados no snapshot, e `restore.compose.json` e `volume-files.sha256` não entram em `configHashes`. Nunca restaure snapshots de terceiros.
- **Sucesso marcado cedo.** O resultado pode ficar como concluído antes de a parada final da cópia restaurada ser confirmada; uma falha de `compose stop` passa despercebida.
- **Checagens tardias.** Destino, ACL e espaço em disco são conferidos depois do restart ou da recriação, não antes.
- **Busca de segredos nos logs.** Parte dos roteiros não confere o exit code de `docker logs`; uma mensagem de erro do Docker não prova que os logs estão limpos.
- **Metadados de mídia.** O backup do SeaweedFS não é transacional com os metadados guardados nos bancos dos serviços.

## Referências oficiais

- [Release 4.53](https://github.com/seaweedfs/seaweedfs/releases/tag/4.53)
- [Licença](https://github.com/seaweedfs/seaweedfs/blob/4.53/LICENSE)
- [Mini](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/command/mini.go)
- [Segurança](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/command/scaffold/security.toml)
- [Wiki mini](https://github.com/seaweedfs/seaweedfs/wiki/Quick-Start-with-weed-mini)

