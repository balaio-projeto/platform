# Scripts locais

## Storage local (PI-213)

`setup-local.ps1` tambem executa `prepare-local-storage.ps1`, antes do primeiro
`docker compose up`. Em ambiente existente, use `./scripts/prepare-local-storage.ps1`
para preparar somente storage. O script aceita `-EnvFile` e `-SecretsDirectory`,
exige caminhos ignorados e nao rastreados pelo Git, e preserva valores validos.
Ele acrescenta somente variaveis S3 ausentes ao `.env`, gera credenciais aleatorias,
certificados RSA 3072 em `secrets/seaweedfs/` e a chave CA em
`secrets/seaweedfs-ca/`. Configuracoes parciais, invalidas ou certificados perto
do vencimento sao recusados sem substituicao automatica.

Usa apenas PowerShell 7.2+/.NET e Git; nao requer OpenSSL no Windows. Os caminhos
alternativos de certificados exigem alinhamento dos mounts do Compose.

Depois de iniciar somente `seaweedfs`, execute
`./scripts/test-local-storage.ps1` para testar host, Docker, bucket privado e
interfaces internas. O roteiro cria e remove apenas um objeto diagnostico unico
em `balaio-media/diagnostics/`. Com `-IncludeSpecialCharacterTest`, cria tambem
uma fixture isolada sem rede, portas publicadas ou volumes de dados, removida
ao final, para testar credenciais com caracteres especiais. Nao imprime segredos.
O setup nunca inicia containers. Veja [storage local](../docs/storage-local.md).

Etapa 5: `./scripts/test-storage-recovery.ps1 -AllowStorageInterruption` testa
persistencia apos reinicio e recriacao, faz backup com parada limpa somente do
storage e restaura em volume/projeto novos. Exige os 13 containers saudaveis.
Guarda snapshot com ACL restrita e manifesto em `backups/seaweedfs-<data>-<id>/`.
`./scripts/restore-local-storage.ps1 -BackupDirectory <snapshot>` recupera somente
do snapshot, sem ler o `.env` principal, sempre em outro volume/projeto novo.
Ambos deixam restauracoes paradas, preservando containers, redes e volumes para
revisao. Nunca sobrescrevem um volume ou backup existente; nao sao scripts de
limpeza. Consulte procedimentos e resultados em [storage local](../docs/storage-local.md).

**Limite de seguranca atual:** snapshots contem credenciais S3 e chaves privadas
sem criptografia. A pasta `backups/` deste workspace esta dentro do OneDrive;
nao executar novos ensaios de backup ali antes de aprovar o endurecimento descrito
no [plano de protecao](../docs/storage-local.md#seguranca-dos-backups--revisao-da-etapa-6).
O restaurador executa scripts e um template Compose vindos do snapshot: aceitar
somente copias locais confiaveis, nunca arquivos recebidos de terceiros. Hashes
detectam corrupcao, mas nao comprovam a origem. A criptografia proposta ainda
nao faz parte destes comandos. Backups existentes nao foram movidos ou alterados.

Execute os comandos abaixo no PowerShell 7.2 ou superior (`pwsh`), a partir de `platform`. Confirme a versão com `pwsh --version`; `powershell.exe` abre o Windows PowerShell 5.1 e não oferece as APIs PEM usadas aqui. Os arquivos `.env`, `secrets/admin.env` e as chaves em `secrets/` ficam fora do Git; `secrets/admin.env.example` é o único exemplo versionado nessa pasta. O teste de integração também exige a API em execução.

| Script | Comando | Efeito |
| --- | --- | --- |
| `setup-local.ps1` | `./scripts/setup-local.ps1` | Em instalação nova, copia `.env.example` para `.env` sem preencher `DB_PASSWORD`, gera o token interno, prepara o par JWT e cria `secrets/admin.env` com duas variáveis vazias. Você define as senhas do banco e do administrador antes do `up`; os comentários do administrador ficam em `secrets/admin.env.example`. Preserva arquivos existentes; se um `.env` existente não tiver token, avisa para executar `prepare-internal-token.ps1` separadamente. Não inicia containers nem altera volumes. |
| `prepare-local-jwt.ps1` | `./scripts/prepare-local-jwt.ps1` | Cria as chaves RSA 3072 em `secrets/` somente se ambas faltarem; sempre valida o par. Não lê nem cria `admin.env`. Se houver só uma chave, interrompe sem substituí-la. |
| `prepare-internal-token.ps1` | `./scripts/prepare-internal-token.ps1` | Exige `.env`. Gera `BALAIO_INTERNAL_TOKEN` se a variável faltar ou estiver vazia; valida um token existente sem substituí-lo. Recusa valor não vazio com menos de 32 caracteres. |
| `test-gateway-commerce-integration.ps1` | `./scripts/test-gateway-commerce-integration.ps1 -GatewayBase http://localhost:8080 -CommerceBase http://localhost:8083` | Roteiro manual de integração do Gateway e commerce. Lê o token de `.env` e o administrador de `secrets/admin.env`; cria contas, peças e pedidos de teste no ambiente indicado. Use apenas um ambiente de teste isolado. |

Para configurar cada segredo separadamente:

```powershell
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
# Defina DB_PASSWORD no .env novo.
./scripts/prepare-local-jwt.ps1
New-Item -ItemType Directory -Path secrets -Force | Out-Null
if (-not (Test-Path secrets/admin.env)) { Set-Content secrets/admin.env -Value 'ADMIN_EMAIL=', 'ADMIN_SENHA_INICIAL=' }
# Defina ADMIN_EMAIL e ADMIN_SENHA_INICIAL em secrets/admin.env antes do up.
./scripts/prepare-internal-token.ps1
```

`setup-local.ps1` aceita `-EnvFile` e `-SecretsDirectory` para preparar caminhos locais alternativos. `prepare-local-jwt.ps1` aceita `-Directory` e `prepare-internal-token.ps1` aceita `-EnvFile`. Mantenha `JWT_PRIVATE_KEY_FILE` e `JWT_PUBLIC_KEY_FILE` do `.env` alinhados com os caminhos preparados antes de iniciar o Compose. Se já houver volumes PostgreSQL, mantenha as credenciais que correspondem a esses bancos; criar uma nova `DB_PASSWORD` não altera senhas gravadas nos volumes.
