# Storage local — PI-213, Etapa 3

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
volume PostgreSQL e alterado. Nao remover volumes para limpeza. Validacao
completa de persistencia e restauracao permanece na Etapa 5.

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

Pendencias: permissoes dos consumidores, limites MIME/tamanho, limpeza delimitada,
backup consistente/restauracao isolada, persistencia completa e leitura pelo
navegador apos reinicio (PI-264). Estas provas nao sao declaradas concluidas.

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

Esta entrega demonstra infraestrutura S3 privada operacional; nao demonstra ainda
leitura de midia pelo navegador nem o roteiro completo de persistencia/backup.

## Referencias oficiais

- [Release 4.53](https://github.com/seaweedfs/seaweedfs/releases/tag/4.53)
- [Licenca](https://github.com/seaweedfs/seaweedfs/blob/4.53/LICENSE)
- [Mini](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/command/mini.go)
- [Seguranca](https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/command/scaffold/security.toml)
- [Wiki mini](https://github.com/seaweedfs/seaweedfs/wiki/Quick-Start-with-weed-mini)
