[CmdletBinding()]
param(
    [switch] $NoBuild,
    [switch] $Check,
    [string] $ProjectDirectory = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.2') { throw 'Execute com PowerShell 7.2+: pwsh -File scripts/start-local.ps1' }
$project = (Resolve-Path -LiteralPath $ProjectDirectory).Path
if (-not (Test-Path -LiteralPath (Join-Path $project 'docker-compose.yml'))) { throw 'docker-compose.yml nao encontrado.' }
Get-Command docker -ErrorAction Stop | Out-Null

function Invoke-LocalCompose([string[]] $Arguments) {
    & docker compose @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose falhou. Confira a mensagem anterior; bancos e volumes nao foram removidos.' }
}

Push-Location $project
try {
    $engine = & docker info --format '{{.ServerVersion}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($Check) { throw 'Docker indisponivel. Inicie o Docker Desktop.' }
        $desktop = Join-Path $env:ProgramFiles 'Docker/Docker/Docker Desktop.exe'
        if (-not $IsWindows -or -not (Test-Path -LiteralPath $desktop)) { throw 'Inicie o Docker e execute novamente.' }
        Start-Process -FilePath $desktop -WindowStyle Hidden
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        do {
            Start-Sleep -Seconds 2
            $engine = & docker info --format '{{.ServerVersion}}' 2>$null
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Docker Desktop nao iniciou em 90 segundos.' }
        } while ($LASTEXITCODE -ne 0)
    }

    $envPath = Join-Path $project '.env'
    if (-not (Test-Path -LiteralPath $envPath)) {
        if ($Check) { throw '.env ausente. Execute sem -Check para preparar o primeiro uso.' }
        # Somente instalacoes novas recebem defaults; arquivos existentes nao sao reescritos.
        $content = [IO.File]::ReadAllText((Join-Path $project '.env.example'))
        $password = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
        $token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
        $defaults = @{
            DB_PASSWORD=$password; BALAIO_INTERNAL_TOKEN=$token; PROFILE_FRONTEND_BASE_URL='http://localhost:4321';
            PROFILE_SMTP_HOST='localhost'; PROFILE_SMTP_PORT='1025';
            PROFILE_SMTP_AUTH='false'; PROFILE_SMTP_STARTTLS='false'; PROFILE_MAIL_FROM='nao-responda@localhost'
        }
        foreach ($name in $defaults.Keys) { $content = [regex]::Replace($content, "(?m)^$name=[^\r\n]*", "$name=$($defaults[$name])") }
        $stream = [IO.File]::Open($envPath, [IO.FileMode]::CreateNew)
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
    }
    $rawEnv = [IO.File]::ReadAllText($envPath)
    $storage = $rawEnv -match '(?m)^MEDIA_S3_ENDPOINT=[ \t]*[^\s\r\n]+'
    $profiles = @('--profile', 'extended')
    $files = @()
    if ($storage) {
        $files = @('-f', 'docker-compose.yml', '-f', 'docker-compose.storage.yml')
        $profiles = $files + $profiles + @('--profile', 'storage')
    }
    Invoke-LocalCompose ($profiles + @('config', '--quiet'))

    # No modo Check, somente leituras. No start, subir primeiro os bancos permite
    # diagnosticar credenciais/historico antes de iniciar ou recriar aplicacoes.
    if (-not $Check) {
        Invoke-LocalCompose ($profiles + @('up', '-d', '--wait', '--wait-timeout', '120',
            'catalog-db', 'profile-db', 'commerce-db', 'community-db', 'events-db'))
    }
    $profileDb = & docker compose ps --status running -q profile-db
    if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel verificar o banco do Profile.' }
    if ($profileDb) {
        $query = "SELECT CASE WHEN EXISTS (SELECT 1 FROM flyway_schema_history WHERE script IN ('V5__create_midias_perfil.sql','V6__protect_media_cleanup.sql','V1__accounts_and_password_recovery.sql')) THEN 'LEGACY' ELSE 'CURRENT' END"
        # Um banco novo ainda nao tem tabela Flyway. Essa verificacao evita erro de SQL.
        $table = & docker compose exec -T profile-db psql -U balaio_profile_app -d balaio_profile -Atc "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL"
        if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel consultar o banco do Profile.' }
        if (($table -join '').Trim() -eq 't') {
            $history = & docker compose exec -T profile-db psql -U balaio_profile_app -d balaio_profile -Atc $query
            if ($LASTEXITCODE -ne 0) { throw 'Falha ao consultar o historico Flyway.' }
            if (($history -join '').Trim() -eq 'LEGACY') {
                throw 'Banco legado incompativel. Siga a transicao com backup descrita no README antes de iniciar. Nenhum historico ou dado foi alterado.'
            }
        }
        if (-not $Check) {
            foreach ($service in @('catalog-db','profile-db','commerce-db','community-db','events-db')) {
                $probe = if ($service -eq 'catalog-db') {
                    'PGPASSWORD="$CATALOG_DB_PASSWORD" psql -h "$1" -U "$CATALOG_DB_USERNAME" -d "$CATALOG_DB_NAME" -Atc "SELECT 1"'
                } else {
                    'PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$1" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT 1"'
                }
                $result = & docker compose exec -T $service sh -c $probe -- $service 2>$null
                if ($LASTEXITCODE -ne 0) { throw "Senha/configuracao de $service nao corresponde ao volume existente. Ajuste o .env com a credencial desse banco; nenhuma senha foi redefinida." }
            }
        }
    }
    if ($Check) {
        Write-Output 'PASS: Compose valido; configuracao existente preservada. Banco parado sera verificado no start.'
        return
    }
    $up = $profiles + @('up', '-d', '--wait', '--wait-timeout', '240')
    if (-not $NoBuild) { $up += '--build' }
    Invoke-LocalCompose $up
    Invoke-LocalCompose ($files + @('ps'))
    Write-Output 'Balaio iniciado. Consulte a porta FRONTEND_HOST_PORT do .env (padrao: http://localhost:4321).'
} finally { Pop-Location }
