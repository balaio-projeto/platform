# Storage local — PI-213, revisao da Etapa 6

Guia operacional local Windows/PowerShell. Infraestrutura e recuperacao foram
testadas nas Etapas 3/5; a revisao final abaixo distingue essas evidencias das
pendencias. **Backups atuais nao sao criptografados e o workspace esta no
OneDrive.** Leia a secao de seguranca antes de gerar uma nova copia. A integracao
de midia com o navegador ainda nao esta implementada.

## Preparar e iniciar

Requisitos: Docker Desktop/Compose, Git e PowerShell 7.2+ (`pwsh`). Certificados
usam somente o .NET do PowerShell, sem OpenSSL ou PKI externa. O provisionamento
de permissoes desta entrega e voltado ao Windows.

Na pasta `platform`, em uma instalacao nova:

```powershell
./scripts/setup-local.ps1
# Preencher DB_PASSWORD e secrets/admin.env; revisar SMTP, origens e portas.
docker compose --profile extended config --quiet
docker compose --profile extended up --build -d
```

Em ambiente ja funcionando, preparar e subir somente o storage:

```powershell
./scripts/prepare-local-storage.ps1
docker compose config --quiet
docker compose --profile extended config --quiet
docker compose up -d --no-deps seaweedfs
docker compose ps seaweedfs
./scripts/test-local-storage.ps1
```

Sao 7 servicos padrao e 13 no `extended`. O storage nao pertence a um profile e
nao adiciona dependencias aos outros servicos. Setup nao inicia containers nem
modifica bancos. JWT, SMTP, token interno e senhas existentes sao preservados.
Nao substituir o `.env`. Sem credenciais, a interpolacao obrigatoria recusa o
Compose: executar o preparador antes, sem desabilitar autenticacao. Em maquina
limpa, senhas de banco/administrador continuam sendo preenchidas pelo usuario.

## Imagem e dados

- Imagem `chrislusf/seaweedfs:4.53`, Apache-2.0.
- Digest `sha256:ccad23e18639c8b98cee17e7100b95830a06077b56d8e5b006d6dcf8ec5e94a0`.
- Binario verificado: `version 30GB 4.53 4ab66fb76 linux amd64`.
- `weed mini -dir=/data`; reinicio `unless-stopped`.
- Volume `balaio-local_seaweedfs-data:/data`, incluindo objetos, metadados do
  filer (`/data/filerldb2`), configuracoes internas e estado administrativo.
- `/tmp` em tmpfs: configuracao S3 temporaria nao pertence ao volume de dados.

O entrypoint oficial ajusta ownership e executa como usuario `seaweed`. Nenhum
volume PostgreSQL e alterado. Nao remover volumes para limpeza. Persistencia do
objeto apos reinicio/recriacao e restauracao isolada foram verificadas na Etapa 5,
conforme os resultados abaixo; leitura pelo navegador continua pendente.

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

Bucket unico **`balaio-media`**, criado idempotentemente e privado. Futuros objetos
devem usar `profile/`, `catalog/` e `community/`; testes usam somente
`diagnostics/pi213-<identificador>.txt`. Prefixos organizam dados, sem substituir
autorizacao.

Identidade `balaio-local-admin`, acao `Admin`, exclusiva do provisionamento local.
Nao entregar ao frontend ou as futuras aplicacoes. Antes de integrar consumidores,
separar identidades/permissoes minimas por dominio e definir limites MIME/tamanho.
Nao ha politica anonima ou objetos publicos. PI-214, PI-175 e PI-200 nao foram
implementados.

Fluxo: Frontend -> API Gateway -> microsservico -> SeaweedFS. Navegador nao envia
arquivos ao storage nem recebe DNS Docker. URL pelo gateway depende dos tickets
funcionais; nenhuma rota administrativa foi criada.

## Testar e diagnosticar

```powershell
docker compose ps seaweedfs
docker compose exec -T seaweedfs /bin/sh /opt/balaio/storage/healthcheck.sh
./scripts/test-local-storage.ps1
./scripts/test-local-storage.ps1 -IncludeSpecialCharacterTest
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

Pendencias: permissoes dos consumidores, alinhamento/aplicacao de limites
MIME/tamanho, limpeza de midias de negocio e leitura pelo navegador apos reinicio
(PI-264). Backup frio e restauracao isolada do storage foram executados na Etapa 5.

## Evidencias da Etapa 3 (11/11/2026)

Executado no Windows, PowerShell 7.6.9 e imagem 4.53 fixada acima:

- CT-01/02: setup no ambiente existente e em pasta de instalacao limpa; repeticao
  manteve hashes do `.env` e dos certificados/chaves. Configuracoes incompletas,
  porta invalida e certificados incompletos/corrompidos foram recusados.
- CT-03: `config --quiet` padrao e extended passaram; 7 e 13 servicos.
- CT-04/05: storage running/healthy, volume nomeado efetivamente montado em
  `/data`; processo weed com UID 1000; restartCount zero na conferencia final.
- CT-06/07/08/09: ListBuckets autenticado no host HTTP 200, anonimo 403,
  HeadBucket privado 200. PUT/GET do objeto temporario com hashes identicos;
  GET anonimo 403; somente esse objeto foi removido (DELETE 204).
- CT-10: HeadBucket assinado pela rede Docker funcionou em outro container.
- CT-11: APIs auxiliares recusaram TLS sem certificado; com certificado valido,
  TLS foi aceito nas sete portas HTTP/gRPC verificadas. Portas opcionais e
  administrativas inacessiveis pela rede; netstat confirmou 12535/22535 em loopback.
- CT-12/13: os 12 containers originais mantiveram IDs e saude; cinco volumes
  PostgreSQL preservados. Hashes de admin/JWT e conteudo nao-S3 do `.env` identicos.
- CT-14: fixture isolada com secret contendo caracteres especiais passou no
  healthcheck real; nenhum dos dois valores apareceu nos logs. Fixture removida,
  sem alterar o volume do Balaio. Logs atuais do storage tambem passaram na busca
  pelos dois valores reais S3, sem imprimi-los.

A Etapa 3 demonstrou infraestrutura S3 privada operacional. A validacao adicional
de persistencia/backup esta abaixo; leitura de midia pelo navegador nao foi testada.

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

Roteiro existente, com interrupcao local explicita. **Nao executar novos backups
na pasta sincronizada atual antes de aprovar a protecao descrita na Etapa 6.**
O comando abaixo registra o procedimento validado na Etapa 5; nao oferece
criptografia nem parametro para escolher um destino fora do repositorio:

```powershell
./scripts/test-storage-recovery.ps1 -AllowStorageInterruption
```

Esse comando e um **ensaio de recuperacao completo**, nao um simples smoke test:
envia um objeto unico, testa restart/recriacao, faz backup e restaura em outro
projeto. Exige os 13 containers principais em execucao e deve ser usado em uma
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
./scripts/restore-local-storage.ps1 -BackupDirectory '.\backups\<snapshot>'
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

## Resultados executados da Etapa 5 — 11/11/2026

Docker Engine 29.9.3 disponivel. Nenhuma alteracao de infraestrutura foi usada
para iniciar o Engine. Testes reais executados no ambiente Windows/PowerShell.

- Upload/download inicial: SHA-256 identico ao arquivo temporario local.
- Restart somente do storage: hash e seis metadados identicos; acesso anonimo 403.
- Recriacao somente do storage: novo container, mesmo volume principal, mesmo
  objeto/hash/metadados; healthcheck aprovado e sem valores S3 nos logs.
- Backup: parada limpa (exit 0), tar valido e **126 arquivos** inventariados.
- Restauracao: todos os 126 hashes conferiram antes de abrir o servidor; o objeto
  restaurado manteve hash e os seis metadados. Mesma imagem 4.53/digest.
- Seguranca: interfaces auxiliares recusaram acesso sem certificado de cliente;
  portas opcionais/administrativas inacessiveis pela rede, no principal e na copia.
- Recuperacao independente: segundo restaurador usou apenas o snapshot, sem ler
  `.env` principal; servidor healthy, objeto com hash identico e leitura anonima 403.
- Reprodutibilidade: setup em pasta limpa isolada, repeticao sem alterar hashes,
  par S3 incompleto recusado e certificados incompletos recusados sem regeneracao.
- Preservacao: IDs e StartedAt dos 12 containers anteriores iguais; todos saudaveis.
  `.env`, administrador, JWT e os quatro arquivos TLS/CA principais com hashes
  identicos; todos os volumes anteriores presentes.
- Compose: configuracoes padrao/extended validas, com 7/13 servicos.

Objeto diagnostico (nao sensivel), SHA-256:

```text
9a0eec558f997c3e1af8818d43f5b65661355a3767b7b3a63fb86e4698bd9fb3
```

Snapshot preservado: `backups/seaweedfs-20261111T160035Z-e30e459312e3/`.
SHA-256 do arquivo `data.tar.gz`:

```text
0dd4b143a278e77c34b07cd935b292fc98e62bc4251a626ffbd4163ee6694e0f
```

Projeto do primeiro restore: `balaio-storage-restore-e30e459312e3`.
Projeto da recuperacao independente: `balaio-storage-recovery-02b44c575e93`.
Ambos foram deixados parados e seus volumes preservados. A aplicacao principal
permanece com 13 containers running/healthy; as duas copias paradas sao adicionais.
Somente o objeto criado pelo ensaio foi removido do storage principal; continua
no backup e nas restauracoes, permitindo conferir a evidencia novamente.

## Seguranca dos backups — revisao da Etapa 6

### Situacao atual e prioridade

**Alta prioridade, antes de novos backups compartilhados:** os dois roteiros
preservam o conjunto recuperavel, incluindo credenciais S3, chave TLS e chave
privada da CA em texto claro. O proprio `/data` pode conter identidades/estado
sensivel. Proteger apenas `s3-credentials.json` nao protege o snapshot completo.
As ACLs limitam acesso local, mas nao impedem que o cliente OneDrive do mesmo
usuario sincronize esses arquivos. Nao foi consultado o historico da conta
OneDrive; nao e possivel afirmar se ja houve sincronizacao.

Git ignore nao e controle de confidencialidade. SHA-256 e tar.gz tambem nao
criptografam nem autenticam a origem do backup. Os snapshots existentes foram
preservados; nao foram apagados, movidos, sobrescritos ou criptografados nesta
revisao. Eventual tratamento das copias locais/remotas e do historico de versoes
precisa de autorizacao e politica de retencao. Criptografar uma nova copia nao
elimina eventual exposicao anterior; nao rotacionar credenciais/CA automaticamente.

### Proposta para aprovacao: age e destino fora da sincronizacao

Usar [age, documentacao oficial](https://github.com/FiloSottile/age), com
criptografia por chave publica. A ferramenta possui binarios Windows e aceita
multiplos destinatarios. A proposta e portavel entre maquinas, desde que a
identidade privada de recuperacao esteja disponivel; nao depende da conta Windows
original. Nao foi instalada nem testada nesta entrega.

1. Preparar diretorio de trabalho fora do repositorio e de qualquer raiz
   sincronizada, por exemplo em disco local dedicado. Validar o caminho resolvido,
   ACL restrita, espaco disponivel e politica de sincronizacao **antes** de parar
   o storage ou copiar segredos. A localizacao, sozinha, nao e prova de protecao.
2. Gerar e guardar a identidade privada age em cofre de senhas/segredo e manter
   copia de recuperacao offline. Nunca inclui-la no Git, OneDrive, snapshot ou
   container. O preparador de backup recebe somente os destinatarios publicos.
   Definir responsavel, segundo destinatario de contingencia e teste de recuperacao.
3. Criar o snapshot frio e manifesto nesse diretorio restrito. Empacotar **todo**
   o conjunto, inclusive certificados, CA, credenciais, scripts, template e
   inventario, em um unico arquivo criptografado com nome unico `.tar.age`.
   Recusar destino existente: `age -o` pode sobrescrever arquivos existentes.
4. Conferir sucesso da criptografia e testar descriptografia/restauracao em area
   restrita antes de aceitar a copia. Copiar para OneDrive ou outro destino apenas
   o artefato criptografado. Verificar hash da copia e guardar procedencia confiavel;
   criptografia para chave publica nao comprova quem produziu o backup.
5. Na recuperacao, descriptografar fora de pastas sincronizadas, validar origem,
   versao/digest aprovado, caminhos do pacote e manifesto. Restaurar somente em
   volume/projeto novos e comparar os hashes antes de qualquer promocao manual.
   Preservar a disponibilidade da chave age; sua perda inviabiliza a recuperacao.
6. Definir retencao e limpeza explicita apenas do staging novo apos validar a
   copia; nao aplicar limpeza a snapshots existentes ou ao volume original.

Implementacao futura exige parametros de staging/destino nos roteiros, recusa de
destinos sincronizados conhecidos, validacao de colisao, empacotamento completo,
tratamento de falhas e fluxo de descriptografia. Testar com fixture sem segredos
reais: round-trip, chave errada, arquivo adulterado, interrupcao e destino existente;
depois ensaio isolado completo autorizado. O restaurador atual recebe uma pasta
descriptografada confiavel; ainda nao recebe `.age` diretamente. Nao e suficiente
executar criptografia depois que o snapshot claro ja foi criado no OneDrive.

### Outros achados dos scripts

- **Alta prioridade, entrada confiavel:** `restore-local-storage.ps1` reutiliza
  scripts e Compose do snapshot. Valida alguns mounts, mas nao impoe esquema
  fechado a todos os servicos, privilegios, entrypoint e recursos do template.
  `restore.compose.json` e `volume-files.sha256` nao estao cobertos por
  `configHashes`; mesmo um manifesto completo continuaria precisando de origem
  confiavel. Nao usar snapshots de terceiros. Antes de ampliar o uso, gerar Compose
  a partir de configuracao local aprovada, fixar digest exato e validar caminhos
  de extracao. O isolamento de dados nao e uma sandbox para codigo nao confiavel.
- **Prioridade media, falhas de operacao:** os roteiros marcam sucesso antes de
  confirmar a parada final da copia restaurada. Uma falha de `compose stop` pode
  deixar `completed=true` e a mensagem final pode indicar parada nao confirmada.
  No ensaio completo, a flag de retomada principal so e marcada depois de `stop`
  retornar sucesso. Registrar e tratar explicitamente esses estados antes de
  reutilizar os roteiros como automacao de backup. Sao achados de leitura de codigo;
  falhas nao foram injetadas e nao invalidam as provas positivas da Etapa 5.
- **Prioridade media, preflight:** conferir destino, ACLs e capacidade antes das
  interrupcoes; hoje parte das verificacoes ocorre depois do restart/recreate.
- **Prioridade media, verificacao de logs:** o restaurador independente e parte
  do smoke test procuram valores secretos no texto retornado por `docker logs`,
  sem conferir sempre seu exit code. Exigir coleta bem-sucedida antes de declarar
  ausencia de vazamento; uma mensagem de erro do Docker nao e evidencia de logs
  limpos. O helper `Check-Logs` do ensaio completo ja confere esse exit code.
- **Manutenibilidade:** o cliente SigV4/.NET aparece nos testes de storage e
  recuperacao. Extrair helper comum somente junto de mudanca testada; nenhuma
  reestruturacao foi feita nesta revisao. O manifesto mistura validacao do ensaio
  com estado do backup; separar esses conceitos em futuro endurecimento.

Nao foram alterados scripts, Compose, credenciais, certificados ou dados nesta
etapa. As correcoes operacionais acima precisam de revisao antes de implementar
e executar novos ensaios. O backup consistente ja demonstrado nao equivale a
backup confidencial pronto para compartilhamento.

## Criterios de aceite: evidencia e pendencias

Referencia de limites da analise da Etapa 4: imagens de perfil/capa de ate
2 MiB, fotos de pecas de ate 5 MiB (cinco por peca) e video inicialmente ate
25 MiB. JPG/PNG/WebP e MP4 compativel com o navegador foram propostos. Sao
parametros de planejamento dos consumidores, ainda sem enforcement S3 novo ou
contratos implementados; exigem alinhamento nos tickets funcionais. O arquivo
diagnostico usado nesta etapa e pequeno e nao comprova desempenho de videos grandes.

PI-213:

- **APROVADO:** infraestrutura Compose e persistencia do storage apos restart/recriacao.
- **PARCIAL:** bucket e privacidade documentados/testados; limites de tipo/tamanho
  ainda exigem alinhamento e aplicacao pelos consumidores.
- **PARCIAL:** upload/leitura host e Docker aprovados; navegador nao foi validado.
- **APROVADO:** credenciais locais/ignoradas e exemplo sem valores reais; setup
  reproduzivel e preservacao de configuracoes existentes demonstrados.
- **APROVADO no criterio de nao apagar dados sem aviso:** backup frio e restauracao isolada
  executados, sem remover volumes/sobrescrever dados. Roteiros limpam somente o
  objeto diagnostico que criaram; limpeza de midias de negocio nao foi implementada.
  **PARCIAL na seguranca operacional adicional:** criptografia e endurecimento dos
  roteiros acima ainda pendentes; este aceite nao autoriza compartilhar backups claros.

PI-264:

- **APROVADO:** imagem, versao, digest e licenca registrados.
- **BLOQUEADO:** upload e leitura pelo navegador apos reinicio dependem da
  integracao funcional; a prova S3 por host/Docker da Etapa 5 e somente parcial.
- **PARCIAL:** bucket privado e ausencia de segredos conhecidos no Git demonstrados; URL
  publica da aplicacao, pelo gateway, ainda nao foi demonstrada.

**REPROVADO:** nenhum teste executado demonstrou falha operacional. Isso nao
significa ausencia de vulnerabilidades; os riscos de backup foram identificados
por revisao e continuam abertos. A leitura pelo
navegador nao foi executada nem marcada como aprovada. Depende de PI-214, PI-175
ou PI-200 implementarem os contratos reais, autorizacao e URLs pelo gateway;
PI-264 referencia explicitamente PI-175/PI-200. Nenhum endpoint demonstrativo foi criado.
Continuam pendentes limites/identidades dos consumidores, integracao da migracao
de binarios do catalogo e backup coordenado dos futuros metadados entre servicos.

Ainda pertencem ao **PI-213**: aprovar/documentar os limites iniciais e politica
publico/privado; provisionar identidades consumidoras com permissoes minimas por
prefixo antes de integrar aplicacoes; proteger backups, endurecer operacao e
completar a evidencia ponta a ponta com as equipes consumidoras. Nao transferir
essas pendencias integralmente para os tickets funcionais.

Dependencias funcionais: **PI-214** integra imagens de perfil/atelie; **PI-175**
integra fotos de pecas, inclusive metadados/migracao do catalogo; **PI-200** integra
midias da comunidade. Cada consumidor deve autorizar upload/leitura/exclusao,
validar conteudo/tamanho, guardar referencias e entregar URLs pelo gateway.
O **PI-264** depende explicitamente de PI-175/PI-200; demonstrar depois leitura
real pelo navegador e repeticao apos reinicio, sem DNS Docker e sem tornar o
bucket publico. Nenhuma dessas funcionalidades foi antecipada.

## Revisao final e preparacao da entrega — 11/11/2026

Verificacoes novas desta Etapa 6, sem restart, upload ou novo backup:

- Docker Engine 29.9.3 disponivel; os 13 servicos principais running/healthy.
- `docker compose config --quiet` e variante `--profile extended` aprovados;
  listagem com 7/13 servicos. `/data` usa `balaio-local_seaweedfs-data`.
- Healthcheck executado explicitamente com exit 0: HeadBucket assinado e
  ListBuckets anonimo recusado. Valores S3 atuais ausentes dos logs examinados.
- `profile-service` continua com `SPRING_PROFILES_ACTIVE=local` e
  `AUTH_COOKIE_SECURE=false`; nenhuma alteracao nos consumidores ou bancos.
- SHA-256 do arquivo de backup e dos arquivos em `configHashes` do snapshot da
  Etapa 5 conferem. Manifesto registra 126 arquivos e ensaio concluido. As duas
  restauracoes anteriores continuam paradas com exit 0; volumes preservados.
- Todos os scripts PowerShell passaram no parser; os tres scripts shell de
  storage passaram em `sh -n` dentro do container. ACL do snapshot com heranca
  desativada e tres regras conferida. Os testes de recuperacao e
  provisionamento nao foram reexecutados nesta revisao: evidencias reais da
  Etapa 5 estao separadas acima. Criptografia nao implementada/testada.
- Varredura do working tree e index Git nao encontrou valores secretos conhecidos
  extraidos da configuracao local nem material PEM privado literal nos arquivos
  candidatos a entrega. Nao e auditoria exaustiva de todo o historico Git ou de
  todos os formatos de segredo. `.env`, chaves e backups permanecem ignorados;
  somente `secrets/admin.env.example` e rastreado dentro de `secrets/`.

Branch: `feat/pi-213-seaweedfs-storage`. Nesta revisao foram editados somente
`README.md`, `scripts/README.md` e este guia, preservando as alteracoes anteriores.
Os novos `test-storage-recovery.ps1` e `restore-local-storage.ps1` continuam
nao rastreados; nao foram adicionados ao stage. Index sem alteracoes preparadas.
`git diff --check` e `git diff --cached --check` passaram (exit 0); repetir antes do envio.
Scripts shell mantem LF por `.gitattributes`; Markdown/PowerShell seguem a
configuracao local de checkout (ha CRLF no Windows e LF em outros arquivos).
O aviso de conversao de `docs/storage-local.md` nao e erro de whitespace.
Nao foi feita normalizacao ampla de arquivos.

Antes da entrega: revisar os dois scripts novos e os achados acima, aprovar o
plano de protecao dos backups, selecionar arquivos explicitamente no stage e
repetir a verificacao de segredos e diffs. Nao adicionar `backups/`, `.env` ou
material privado com `git add -f`. Nunca remover volumes PostgreSQL ou
`seaweedfs-data`; nao executar `docker compose down -v` ou prune de volumes.
Nenhum commit, push, merge ou PR foi realizado nesta etapa. Nao fechar os
tickets como integralmente concluidos enquanto os criterios parciais/bloqueados
permanecerem abertos.

## Referencias oficiais

- [Release 4.53](https://github.com/seaweedfs/seaweedfs/releases/tag/4.53)
- [Licenca](https://github.com/seaweedfs/seaweedfs/blob/4.53/LICENSE)
- [Mini](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/command/mini.go)
- [Seguranca](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/command/scaffold/security.toml)
- [Wiki mini](https://github.com/seaweedfs/seaweedfs/wiki/Quick-Start-with-weed-mini)
