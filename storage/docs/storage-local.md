# Storage local (SeaweedFS): operação e segurança

Guia operacional do storage S3 local, para Windows/PowerShell. Para habilitar o
storage e ver o acesso do Profile Service, comece pelo [README do storage](../README.md).
**Os backups não são criptografados**: leia [Segurança dos backups](#segurança-dos-backups)
antes de gerar uma cópia.

## Preparar e iniciar

Requisitos: Docker Desktop/Compose, Git e PowerShell 7.2+ (`pwsh`). Certificados
usam somente o .NET do PowerShell, sem OpenSSL ou PKI externa. O provisionamento
de permissoes desta entrega e voltado ao Windows.

Na pasta `platform`, o `.env` precisa existir (`start-local.ps1` ou cópia do
`.env.example`). Pilha completa com storage:

```powershell
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
- Binario verificado: `version 30GB 4.53 4ab66fb76 linux amd64`.
- `weed mini -dir=/data`; reinicio `unless-stopped`.
- Volume `balaio-local_seaweedfs-data:/data`, incluindo objetos, metadados do
  filer (`/data/filerldb2`), configuracoes internas e estado administrativo.
- `/tmp` em tmpfs: configuracao S3 temporaria nao pertence ao volume de dados.

O entrypoint oficial ajusta ownership e executa como usuario `seaweed`. Nenhum
volume PostgreSQL e alterado. Nao remover volumes para limpeza.

## Provisionamento idempotente

`prepare-local-storage.ps1` aceita `-EnvFile` e `-SecretsDirectory`; caminhos devem
estar ignorados e nao rastreados pelo Git. Caminhos alternativos de certificados
exigem alinhar os mounts do Compose. Configuracoes parciais exigem recuperacao
explicita; evitar edicoes concorrentes durante o setup.

Quando ambos os valores faltam ou estao vazios, gera `S3_ACCESS_KEY_ID` com
16 bytes aleatorios (128 bits) e `S3_SECRET_ACCESS_KEY` com 32 bytes (256 bits),
em hexadecimal. Acrescenta `S3_HOST_PORT=8333` se ausente/vazia. Um par existente
valido permanece identico. Apenas uma credencial preenchida, duplicatas, valores
invalidos e portas invalidas provocam erro, sem substituir valores invalidos.

Access key: 20–128 caracteres alfanumericos, `_` ou `-`. Secret: 40–256 caracteres
ASCII imprimiveis. No `.env`, valores com `$`, `#`, espacos ou aspas duplas usam
aspas simples literais; apostrofo interno usa `\'`. Prefira o hexadecimal gerado.
O healthcheck suporta caracteres especiais sem interpretar o segredo como codigo.

Nao executar `docker compose config` sem `--quiet` ou filtragem: a configuracao
resolvida contem segredos. Nao colocar valores reais em comandos, tickets ou Git.

## Certificados e recuperacao

Quando nenhum arquivo existe, gera RSA 3072/SHA-256:

- `secrets/seaweedfs/ca.crt`: CA publica, validade de dez anos.
- `secrets/seaweedfs/tls.crt`: certificado de dois anos; CN `seaweedfs-internal`,
  SAN DNS `seaweedfs`/`localhost` e IP `127.0.0.1`, EKUs serverAuth/clientAuth.
- `secrets/seaweedfs/tls.key`: chave privada interna.
- `secrets/seaweedfs-ca/ca.key`: chave privada CA, nunca montada no container.

Diretorios novos recebem ACLs limitadas ao usuario Windows, SYSTEM e
Administradores. Docker Desktop deve usar o contexto desse usuario. Somente o
storage recebe `secrets/seaweedfs/`, read-only. Microsservicos usarao S3 e nao
devem receber certificados/chaves de cliente TLS.

O preparador valida cadeia, validade (margem de sete dias), identidade, SAN,
EKUs e correspondencia das chaves. Preserva certificados validos byte a byte;
recusa conjuntos parciais/corrompidos/vencidos, sem rotacao silenciosa. Nao altera
a trust store do Windows. Arquivos sensiveis ficam fora do Git.

Preservar `.env`, os dois diretorios de certificados/CA e o volume de dados.
Para recuperar configuracao: parar somente `seaweedfs`, restaurar o conjunto
completo correspondente de uma copia protegida, executar o preparador para
validar e `up -d --no-deps seaweedfs`. Nao remover volumes nem trocar senhas de
bancos/JWT. Certificados internos nao sao chaves de criptografia dos objetos.

Sem copia de um conjunto incompleto/vencido, preservar os arquivos antigos em
local protegido e realizar regeneracao/rotacao explicita com storage parado e
teste isolado. Nao existe reset automatico nesta etapa. Novas credenciais S3 nao
revogam necessariamente identidades antigas no IAM persistido: conferir/revogar
explicitamente ao rotacionar, sem apagar dados.

## Rede e protecoes

S3 interno `http://seaweedfs:8333`; host `http://localhost:8333`, publicado somente
em `127.0.0.1:${S3_HOST_PORT:-8333}`. HTTP e adequado somente a rede Docker local
confiavel; esta nao e configuracao de producao.

O mini compartilha `-ip.bind`; ausencia de portas publicadas nao protege a rede.
Por isso mantemos mTLS nas interfaces auxiliares:

- Master HTTPS 9333 / gRPC 19333.
- Volume HTTPS 9340 / gRPC 19340.
- Filer HTTPS 8888 / gRPC 18888; listagem/metadados de diretorios desativados.
- S3 HTTP 8333 exige SigV4; gRPC 18333 exige mTLS.
- Clientes internos de administracao/worker tambem usam o certificado mTLS.
- WebDAV, Iceberg, Lance e portas administrativas legadas desativados.
- Administracao HTTP 12535 e controle gRPC 22535 somente em loopback dentro do
  container, sem publicacao e inacessiveis pela rede Docker.

Na versao 4.53, `admin.ui=false` impede o listener esperado pelo proprio readiness
e provoca encerramento apos dois minutos. Mantemos a UI em loopback com o padrao
seguro da versao, sem `allowInsecureBind`. Nao configurar senha/https.admin nem
alterar bind administrativo sem reavaliar exposicao: isso pode habilitar bind
externo nessa versao.

O fallback AWS por ambiente registra a access key no log nativo. `start.sh`
valida credenciais, constroi JSON escapado em tmpfs (0600/usuario seaweed), remove
as variaveis AWS do processo weed e passa `-s3.config` antes dos outros argumentos.
Docker mantem as variaveis para healthchecks; valores nao entram em argv.
Credenciais/certificados ausentes e argumentos posicionais invalidos sao
recusados antes de iniciar weed. Nao ha fallback anonimo.

O administrador do host/Docker ainda pode inspecionar segredos. O aviso nativo
de IAM gRPC sem JWT nao significa porta publica: transporte Filer exige mTLS e
foi testado sem certificado de cliente.

## Bucket e permissoes

Bucket unico **`balaio-media`**, criado idempotentemente e privado. Os objetos
usam os prefixos `profile/`, `catalog/` e `community/`; os testes usam somente
`diagnostics/pi213-<identificador>.txt`. Prefixos organizam dados, sem substituir
autorizacao.

Ha duas identidades: `balaio-local-admin` (acao `Admin`, exclusiva do
provisionamento e dos testes locais, nunca entregue ao frontend nem aos servicos)
e `balaio-profile-service`, limitada a `profile/*` (ver o
[README do storage](../README.md#acesso-do-profile-service)). Catalog e Community
ainda nao usam o storage; quando usarem, cada um precisa da propria identidade com
permissoes minimas no seu prefixo. Nao ha politica anonima nem objetos publicos.

Fluxo: Frontend -> API Gateway -> microsservico -> SeaweedFS. O navegador nao envia
arquivos ao storage nem recebe nomes DNS do Docker.

## Testar e diagnosticar

```powershell
docker compose ps seaweedfs
docker compose exec -T seaweedfs /bin/sh /opt/balaio/storage/healthcheck.sh
./storage/scripts/test-local-storage.ps1
./storage/scripts/test-local-storage.ps1 -IncludeSpecialCharacterTest
```

O roteiro usa SigV4 via HttpClient/.NET no host, sem AWS CLI. Testa ListBuckets,
HeadBucket, upload/download com hashes identicos e recusa anonima. Remove somente
o objeto diagnostico unico que acabou de criar. Um cliente Docker separado recebe
somente CA publica, sem chave/certificado de cliente, para testar as interfaces.

CT-14 opcional: container sem rede, sem portas publicadas, `/data` e `/tmp` em
tmpfs, sem volume persistente. A fixture rotulada e removida ao concluir. Testa
autenticacao real com espacos, aspas, barra invertida, `$`, `#`, `+`, `/`, `=`, `:`
e ausencia dos valores nos logs.

Healthcheck: HeadBucket assinado precisa funcionar e ListBuckets anonimo retornar
403. Credenciais escapadas vao por stdin ao curl; saida descartada. Nao substitui
teste completo de persistencia/backup.

Falha de autenticacao: executar preparador para validar, conferir par S3 sem
imprimi-lo, bucket e relogio. Recriar somente storage apos mudar variaveis;
restart nao atualiza ambiente. Nao desabilitar assinatura ou mTLS. Probes HTTP
nativos contra HTTPS podem gerar mensagens de handshake no startup; healthcheck
S3 e os testes devem passar. Inspecionar logs somente com filtragem; o roteiro
confere em memoria que nenhum dos dois valores S3 reais aparece nos logs atuais.

## Operacao segura: reinicio e recriacao

Conferir o Engine antes de qualquer operacao. Se indisponivel, interromper o
roteiro e registrar bloqueio; nao alterar Compose, redes ou Docker para contornar.

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

Recriacao e necessaria quando mudam variaveis; restart nao atualiza ambiente.
Nao executar down com remocao de volumes, volume prune ou volume rm. Nenhum
procedimento abaixo remove volumes, nem mesmo os volumes isolados de validacao.

## Backup consistente e verificavel

Para esta instalacao single-node, foi adotada copia fria de **todo** `/data`,
com SeaweedFS parado. Copiar somente arquivos de volume sem os metadados do
filer nao e suficiente. A documentacao oficial tambem exige coordenar dados e
metadados e recomenda a mesma versao na recuperacao:
[Data Backup](https://github.com/seaweedfs/seaweedfs/wiki/Data-Backup).

O roteiro exige interrupcao local explicita do storage. **Nao gere backups em
pasta sincronizada** (ver [Seguranca dos backups](#segurança-dos-backups)). Ele nao
criptografa o snapshot nem permite escolher um destino fora do repositorio:

```powershell
./storage/scripts/test-storage-recovery.ps1 -AllowStorageInterruption
```

Esse comando e um **ensaio de recuperacao completo**, nao um simples smoke test:
envia um objeto unico, testa restart/recriacao, faz backup e restaura em outro
projeto. Exige a pilha em execucao e deve ser usado em uma
janela em que o storage possa ficar temporariamente indisponivel.

O procedimento implementado no roteiro e:

1. Registrar IDs/StartedAt dos outros 12 containers e hashes dos arquivos
   protegidos, sem registrar seus valores.
2. Criar destino unico `backups/seaweedfs-<UTC>-<id>/`, recusando destino existente.
   Aplicar ACL somente para usuario Windows, SYSTEM e Administradores.
3. Parar somente `seaweedfs` com timeout de 60 segundos; exigir processo parado
   com exit code zero. Nao declarar backup consistente apos parada forcada.
4. Montar o volume original **read-only** em helper sem rede, usando a mesma
   imagem fixada. Gerar `data.tar.gz` e `volume-files.sha256` para todos os arquivos.
5. Guardar versao/digest e configuracao no template Compose de restauracao, copiar
   scripts, certificados e chave CA e guardar somente as credenciais S3 necessarias.
   Senhas PostgreSQL, JWT e credenciais do administrador Balaio nao sao copiadas.
6. Validar leitura do tar e calcular SHA-256 do arquivo. Reiniciar somente o storage
   principal em bloco finally, inclusive se a copia falhar; aguardar healthy.
7. Restaurar e verificar o snapshot isoladamente antes de considerar a prova aprovada.

Conteudo do snapshot:

- `data.tar.gz`: dados, indices, metadados do filer, estado interno e chaves internas.
- `volume-files.sha256`: inventario de integridade antes da inicializacao restaurada.
- `config/storage/`: scripts e configuracao de seguranca da versao testada.
- `config/secrets/seaweedfs/` e `config/secrets/seaweedfs-ca/`: material TLS original.
- `config/s3-credentials.json`: credenciais recuperaveis; **arquivo sensivel**.
- `restore.compose.json`: imagem/digest, argumentos, healthcheck e mounts do snapshot;
  usa placeholders de ambiente, nao valores literais das credenciais.
- `manifest.json`: resultados, hash do tar, hash do objeto e hashes da configuracao.

O snapshot nao inclui dados temporarios de `/tmp`: a configuracao S3 efemera e
reconstruida com as credenciais recuperadas. Arquivos LevelDB mudam normalmente
quando o servidor abre; verificar o inventario antes da primeira inicializacao,
nao exigir os mesmos hashes dos arquivos internos apos o servidor funcionar.

Backups sao ignorados pelo Git e contem segredos em texto claro, protegidos por
ACL, **sem criptografia do arquivo**. Nao publicar nem anexar a tickets. O workspace
atual esta em OneDrive; confirmar a politica de sincronizacao antes de manter
copias sensiveis ali e guardar copia externa protegida/criptografada para sobreviver
a perda do host. ACL e checksum nao substituem criptografia nem backup fora do host.

Este procedimento garante consistencia do SeaweedFS single-node parado. Ainda
nao constitui backup transacional dos futuros metadados de midia nos bancos dos
microsservicos: esse alinhamento sera necessario quando os uploads forem integrados.

## Restaurar um backup existente, sem acessar a instalacao principal

```powershell
./storage/scripts/restore-local-storage.ps1 -BackupDirectory '.\backups\<snapshot>'
```

O restaurador usa `--env-file` vazio explicito para impedir a descoberta automatica
do `.env` principal pelo Compose. Nao chama o setup principal e nao para
o Balaio. O backup original nao e sobrescrito. Ele:

1. Exige manifesto de ensaio concluido, confere o SHA-256 do tar e os hashes de
   configuracoes/certificados e exige tag 4.53 com digest SHA-256 informado no
   template. O script ainda nao compara esse digest com uma lista de aprovados.
2. Cria um volume com nome unico; recusa volume existente e exige destino vazio
   antes de extrair. Nao recebe um parametro que permita apontar para o volume original.
3. Extrai com helper sem rede e verifica todos os arquivos antes de iniciar o servidor.
4. Cria Compose de sessao em `backups/restore-session-<id>/`, ajustando caminhos
   para o snapshot selecionado. Nao altera o template original.
5. Sobe somente SeaweedFS em projeto/rede exclusivos; publica S3 em porta aleatoria
   de `127.0.0.1`, usando certificados e credenciais somente do snapshot.
6. Aguarda healthy, recupera o objeto diagnostico, compara SHA-256 e exige 403
   para leitura anonima. Verifica logs sem exibir credenciais.
7. Para a restauracao, preservando container/rede/volume para revisao; grava
   resultado nao sensivel em `restore-result.json` da sessao.

O ensaio completo tambem compara Content-Type, Content-Length, ETag,
Last-Modified e os metadados personalizados `pi213-run`/`sha256` e testa a
seguranca das interfaces auxiliares a partir da rede isolada.

Nunca usar estes roteiros para sobrescrever a instalacao principal. Uma futura
promocao da recuperacao exige janela e revisao separadas. Manter o conjunto TLS,
as credenciais e a versao correspondentes; nao executar geracao automatica para
"consertar" um snapshot incompleto. O checksum detecta corrupcao em relacao ao
manifesto confiavel; nao autentica um backup fornecido por terceiros.

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

## Referencias oficiais

- [Release 4.53](https://github.com/seaweedfs/seaweedfs/releases/tag/4.53)
- [Licenca](https://github.com/seaweedfs/seaweedfs/blob/4.53/LICENSE)
- [Mini](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/command/mini.go)
- [Seguranca](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/command/scaffold/security.toml)
- [Wiki mini](https://github.com/seaweedfs/seaweedfs/wiki/Quick-Start-with-weed-mini)

