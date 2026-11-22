$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.2') { throw 'Requer PowerShell 7.2+.' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $env:COMPOSE_FILE) { $env:COMPOSE_FILE = ('docker-compose.yml', 'docker-compose.storage.yml') -join [IO.Path]::PathSeparator }
$names = @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'MEDIA_S3_ACCESS_KEY_ID',
    'MEDIA_S3_SECRET_ACCESS_KEY', 'MEDIA_S3_ENDPOINT')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
Push-Location $repo
try {
    $raw = & docker compose --profile extended --profile storage config --format json
    if ($LASTEXITCODE -ne 0) { throw 'Compose invalido; execute o preparador.' }
    $config = $raw | ConvertFrom-Json
    $storage = $config.services.seaweedfs
    $profile = $config.services.'profile-service'
    $env:AWS_ACCESS_KEY_ID = $storage.environment.AWS_ACCESS_KEY_ID
    $env:AWS_SECRET_ACCESS_KEY = $storage.environment.AWS_SECRET_ACCESS_KEY
    $env:MEDIA_S3_ACCESS_KEY_ID = $profile.environment.MEDIA_S3_ACCESS_KEY_ID
    $env:MEDIA_S3_SECRET_ACCESS_KEY = $profile.environment.MEDIA_S3_SECRET_ACCESS_KEY
    $env:MEDIA_S3_ENDPOINT = $profile.environment.MEDIA_S3_ENDPOINT
    if ($env:MEDIA_S3_ACCESS_KEY_ID -ceq $env:AWS_ACCESS_KEY_ID -or
            $env:MEDIA_S3_SECRET_ACCESS_KEY -ceq $env:AWS_SECRET_ACCESS_KEY) {
        throw 'Identidades S3 nao sao independentes.'
    }
    $profileId = & docker compose ps -q profile-service
    if ($LASTEXITCODE -ne 0 -or -not $profileId) { throw 'Profile Service indisponivel.' }
    $instance = (& docker inspect $profileId) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao inspecionar Profile Service.' }
    foreach ($key in @('MEDIA_S3_ENDPOINT', 'MEDIA_S3_REGION', 'MEDIA_S3_BUCKET',
            'MEDIA_S3_ACCESS_KEY_ID', 'MEDIA_S3_SECRET_ACCESS_KEY')) {
        if (@($instance.Config.Env) -cnotcontains ($key+'='+$profile.environment.$key)) {
            throw 'Configuracao S3 nao aplicada ao container do Profile Service.'
        }
    }
    if (@($instance.Config.Env | Where-Object { $_ -match '^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)=' }).Count) {
        throw 'Profile Service recebeu variaveis administrativas S3.'
    }
    foreach ($service in $config.services.PSObject.Properties) {
        if ($service.Name -in @('seaweedfs', 'profile-service')) { continue }
        foreach ($value in $service.Value.environment.PSObject.Properties.Value) {
            if ($value -ceq $env:MEDIA_S3_ACCESS_KEY_ID -or $value -ceq $env:MEDIA_S3_SECRET_ACCESS_KEY) {
                throw 'Credencial consumidora repassada a servico inesperado.'
            }
        }
    }
    Write-Output 'PASS: identidade independente, entregue somente ao storage e Profile Service'
    $mount = 'type=bind,source=' + (Join-Path $repo 'storage') + ',target=/opt/balaio/storage,readonly'
    & docker run --rm --label balaio.validation=pi214-profile-access --read-only --tmpfs /tmp --tmpfs /data `
        --network $config.networks.default.name --entrypoint /bin/sh --mount $mount `
        --env AWS_ACCESS_KEY_ID --env AWS_SECRET_ACCESS_KEY --env MEDIA_S3_ACCESS_KEY_ID `
        --env MEDIA_S3_SECRET_ACCESS_KEY --env MEDIA_S3_ENDPOINT `
        $storage.image /opt/balaio/storage/test-profile-access.sh
    if ($LASTEXITCODE -ne 0) { throw 'Teste de permissoes S3 falhou.' }
    $id = & docker compose ps -q seaweedfs
    if ($LASTEXITCODE -ne 0 -or -not $id) { throw 'Storage principal indisponivel.' }
    $logs = @(& docker logs $id 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao coletar logs.' }
    foreach ($name in $names | Where-Object { $_ -ne 'MEDIA_S3_ENDPOINT' }) {
        $secret = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($secret) -or $logs.Contains($secret)) {
            throw 'Credencial ausente ou presente nos logs; valores omitidos.'
        }
    }
    Write-Output 'PASS: quatro valores S3 ausentes dos logs'
} finally {
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
    Pop-Location
}
exit 0
