# Scripts locais

## Storage local (PI-213)

O PI-214 acrescenta uma identidade S3 do Profile Service ao mesmo preparador.
`test-storage-provisioning.ps1` verifica geracao e idempotencia em fixture isolada.
`test-profile-storage.ps1` verifica o acesso por prefixo na rede Docker, as variaveis
do container e os logs. Procedimento e excecao aceita de ListBuckets vazio estao
no [guia S3 do Profile Service](../docs/pi-214-s3.md).

O storage e opcional e nao faz parte do primeiro start. Para habilitá-lo, use
`./scripts/prepare-local-storage.ps1` depois de ter o `.env`. O script aceita `-EnvFile` e `-SecretsDirectory`,
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

Execute os comandos abaixo no PowerShell 7.2 ou superior (`pwsh`), a partir de `platform`. Confirme a versão com `pwsh --version`; `powershell.exe` abre o Windows PowerShell 5.1 e não oferece as APIs usadas aqui. Os arquivos `.env` e `secrets/` ficam fora do Git.

| Script | Comando | Efeito |
| --- | --- | --- |
| `start-local.ps1` | `pwsh -File scripts/start-local.ps1` | Ponto de entrada. Cria o `.env` se faltar (senha de banco e token interno aleatórios), confere credenciais e bancos legados, sobe os bancos, depois faz build e espera a saúde de todos os serviços. `-NoBuild` usa as imagens existentes; `-Check` só lê. Não remove volumes. |
| `test-gateway-commerce-integration.ps1` | `./scripts/test-gateway-commerce-integration.ps1 -GatewayBase http://localhost:8080 -CommerceBase http://localhost:8083` | Roteiro manual de integração do Gateway e commerce. Lê o token de `.env` e o administrador de `.env` (`ADMIN_EMAIL`, `ADMIN_SENHA_INICIAL`); cria contas, peças e pedidos de teste no ambiente indicado. Use apenas um ambiente de teste isolado. |

O par JWT é gerado pelo `profile-service` no volume do Compose; não há chaves para preparar em `secrets/`. O administrador inicial só é criado se `ADMIN_EMAIL` e `ADMIN_SENHA_INICIAL` (mínimo de 12 caracteres) estiverem no `.env`. Se já houver volumes PostgreSQL, mantenha as credenciais que correspondem a esses bancos; uma nova `DB_PASSWORD` não altera senhas gravadas nos volumes.

### Integracao PI-214 com a develop

O storage e opcional: a pilha padrao continua iniciando sem provisionamento.
Executar prepare-local-storage.ps1 e uma acao explicita para gerar/preservar
as credenciais consumidoras e habilitar MEDIA_S3_ENDPOINT. Inicie o perfil
storage junto de extended ao utilizar midia.

`test-storage-provisioning.ps1` utiliza somente uma pasta fixture ignorada.
`test-profile-storage-isolated.ps1` verifica as permissoes em container sem rede,
sem portas e com dados em tmpfs; credenciais aleatorias nao sao gravadas no repo.
Os roteiros que verificam containers reais respeitam COMPOSE_FILE e
COMPOSE_PROJECT_NAME; selecione o projeto correto antes de executa-los.
Veja docs/pi-214-s3.md para o override local e as restricoes dos bancos legados.
