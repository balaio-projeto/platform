$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.2') { throw 'Requer PowerShell 7.2+.' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $env:COMPOSE_FILE) { $env:COMPOSE_FILE = ('docker-compose.yml', 'docker-compose.storage.yml') -join [IO.Path]::PathSeparator }
$names = @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'CATALOG_S3_ACCESS_KEY_ID',
    'CATALOG_S3_SECRET_ACCESS_KEY', 'CATALOG_S3_ENDPOINT')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
Push-Location $repo
try {
    $raw = & docker compose --profile extended --profile storage config --format json
    if ($LASTEXITCODE -ne 0) { throw 'Compose invalido; execute o preparador.' }
    $config = $raw | ConvertFrom-Json
    $storage = $config.services.seaweedfs
    $catalog = $config.services.'catalog-service'
    $profile = $config.services.'profile-service'
    $env:AWS_ACCESS_KEY_ID = $storage.environment.AWS_ACCESS_KEY_ID
    $env:AWS_SECRET_ACCESS_KEY = $storage.environment.AWS_SECRET_ACCESS_KEY
    $env:CATALOG_S3_ACCESS_KEY_ID = $catalog.environment.CATALOG_S3_ACCESS_KEY_ID
    $env:CATALOG_S3_SECRET_ACCESS_KEY = $catalog.environment.CATALOG_S3_SECRET_ACCESS_KEY
    $env:CATALOG_S3_ENDPOINT = $catalog.environment.CATALOG_S3_ENDPOINT
    if ($catalog.environment.CATALOG_S3_ENABLED -ne 'true') { throw 'CATALOG_S3_ENABLED nao esta ativo no catalog-service.' }
    if ([string]::IsNullOrEmpty($env:CATALOG_S3_ACCESS_KEY_ID) -or
            $storage.environment.CATALOG_S3_ACCESS_KEY_ID -cne $env:CATALOG_S3_ACCESS_KEY_ID -or
            $storage.environment.CATALOG_S3_SECRET_ACCESS_KEY -cne $env:CATALOG_S3_SECRET_ACCESS_KEY) {
        throw 'Par do catalogo ausente ou diferente entre storage e catalog-service.'
    }
    foreach ($other in @(@($env:AWS_ACCESS_KEY_ID, $env:AWS_SECRET_ACCESS_KEY),
            @($profile.environment.MEDIA_S3_ACCESS_KEY_ID, $profile.environment.MEDIA_S3_SECRET_ACCESS_KEY))) {
        if ($env:CATALOG_S3_ACCESS_KEY_ID -ceq $other[0] -or $env:CATALOG_S3_SECRET_ACCESS_KEY -ceq $other[1]) {
            throw 'Identidade do catalogo nao e independente.'
        }
    }
    $catalogId = & docker compose ps -q catalog-service
    if ($LASTEXITCODE -ne 0 -or -not $catalogId) { throw 'Catalog Service indisponivel.' }
    $instance = (& docker inspect $catalogId) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao inspecionar Catalog Service.' }
    foreach ($key in @('CATALOG_S3_ENABLED', 'CATALOG_S3_ENDPOINT', 'CATALOG_S3_REGION', 'CATALOG_S3_BUCKET',
            'CATALOG_S3_ACCESS_KEY_ID', 'CATALOG_S3_SECRET_ACCESS_KEY')) {
        if (@($instance.Config.Env) -cnotcontains ($key + '=' + $catalog.environment.$key)) {
            throw 'Configuracao S3 nao aplicada ao container do Catalog Service; recrie o servico.'
        }
    }
    if (@($instance.Config.Env | Where-Object { $_ -match '^(AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)|MEDIA_S3_(ACCESS_KEY_ID|SECRET_ACCESS_KEY))=' }).Count) {
        throw 'Catalog Service recebeu credenciais de outra identidade S3.'
    }
    foreach ($service in $config.services.PSObject.Properties) {
        if ($service.Name -in @('seaweedfs', 'catalog-service')) { continue }
        foreach ($value in $service.Value.environment.PSObject.Properties.Value) {
            if ($value -ceq $env:CATALOG_S3_ACCESS_KEY_ID -or $value -ceq $env:CATALOG_S3_SECRET_ACCESS_KEY) {
                throw 'Credencial do catalogo repassada a servico inesperado.'
            }
        }
    }
    Write-Output 'PASS: identidade balaio-catalog independente, entregue somente ao storage e Catalog Service'
    $mount = 'type=bind,source=' + (Join-Path $repo 'storage') + ',target=/opt/balaio/storage,readonly'
    & docker run --rm --label balaio.validation=pi175-catalog-access --read-only --tmpfs /tmp --tmpfs /data `
        --network $config.networks.default.name --entrypoint /bin/sh --mount $mount `
        --env AWS_ACCESS_KEY_ID --env AWS_SECRET_ACCESS_KEY --env CATALOG_S3_ACCESS_KEY_ID `
        --env CATALOG_S3_SECRET_ACCESS_KEY --env CATALOG_S3_ENDPOINT `
        $storage.image /opt/balaio/storage/test-catalog-access.sh
    if ($LASTEXITCODE -ne 0) { throw 'Teste de permissoes S3 do catalogo falhou.' }
    foreach ($container in @('seaweedfs', 'catalog-service')) {
        $id = & docker compose ps -q $container
        if ($LASTEXITCODE -ne 0 -or -not $id) { throw "$container indisponivel." }
        $logs = @(& docker logs $id 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
        foreach ($name in $names | Where-Object { $_ -ne 'CATALOG_S3_ENDPOINT' }) {
            $secret = [Environment]::GetEnvironmentVariable($name)
            if ([string]::IsNullOrWhiteSpace($secret) -or $logs.Contains($secret)) {
                throw 'Credencial ausente ou presente nos logs; valores omitidos.'
            }
        }
    }
    Write-Output 'PASS: credenciais S3 ausentes dos logs do storage e do Catalog Service'
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
