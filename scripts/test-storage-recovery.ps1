param([switch] $AllowStorageInterruption)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.2' -or -not $IsWindows) {
    throw 'Requer PowerShell 7.2+ no Windows (ACLs locais).'
}
if (-not $AllowStorageInterruption) {
    throw 'Este teste interrompe somente seaweedfs. Use -AllowStorageInterruption apos planejar a janela local.'
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $repo
$http = [Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds(20)
$savedAccess = [Environment]::GetEnvironmentVariable('PI213_RESTORE_ACCESS')
$savedSecret = [Environment]::GetEnvironmentVariable('PI213_RESTORE_SECRET')
$oldAwsAccess = [Environment]::GetEnvironmentVariable('AWS_ACCESS_KEY_ID')
$oldAwsSecret = [Environment]::GetEnvironmentVariable('AWS_SECRET_ACCESS_KEY')
$stoppedSource = $false
$restoreStarted = $false
$uploaded = $false
$localFile = $null
$complete = $false
$run = [Guid]::NewGuid().ToString('N')
$project = 'balaio-storage-restore-' + $run.Substring(0, 12)
$restoreVolume = $project + '-data'
$key = '/balaio-media/diagnostics/pi213-persistence-' + $run + '.txt'
$backup = Join-Path $repo ('backups/seaweedfs-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + $run.Substring(0, 12))
$composeFile = Join-Path $backup 'restore.compose.json'
$results = [ordered]@{ run = $run; startedUtc = [DateTime]::UtcNow.ToString('o'); backup = $backup; restoreProject = $project; restoreVolume = $restoreVolume; objectPath = $key; checks = [ordered]@{} }

function Docker-OK([string[]] $Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Operacao Docker falhou; nenhum valor de segredo foi exibido.' }
}
function Pass([string] $Name, [string] $Detail) {
    $results.checks[$Name] = $Detail
    Write-Output ('PASS ' + $Name + ': ' + $Detail)
}
function Hash-Hex([byte[]] $Data) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Data)).ToLowerInvariant()
}
function Hmac([byte[]] $KeyBytes, [string] $Text) {
    return ,([Security.Cryptography.HMACSHA256]::HashData($KeyBytes, [Text.Encoding]::UTF8.GetBytes($Text)))
}
function S3([string] $Method, [string] $Path, [string] $Base = $script:sourceEndpoint,
        [byte[]] $Body = @(), [switch] $Anonymous, [switch] $DiagnosticMetadata) {
    $uri = [Uri]::new($Base + $Path)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $uri)
    try {
        $signed = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
        if ($Method -eq 'PUT') {
            $request.Content = [Net.Http.ByteArrayContent]::new($Body)
            $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('text/plain')
            $signed['content-type'] = 'text/plain'
        }
        if (-not $Anonymous) {
            $date = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
            $day = $date.Substring(0, 8)
            $signed['host'] = $uri.Authority
            $signed['x-amz-content-sha256'] = Hash-Hex $Body
            $signed['x-amz-date'] = $date
            if ($DiagnosticMetadata) {
                $signed['x-amz-meta-pi213-run'] = $run
                $signed['x-amz-meta-sha256'] = Hash-Hex $Body
            }
            $canonicalHeaders = ($signed.GetEnumerator() | ForEach-Object { $_.Key + ':' + $_.Value + "`n" }) -join ''
            $names = $signed.Keys -join ';'
            $canonical = "$Method`n$Path`n`n$canonicalHeaders`n$names`n$(Hash-Hex $Body)"
            $scope = "$day/us-east-1/s3/aws4_request"
            $toSign = "AWS4-HMAC-SHA256`n$date`n$scope`n$(Hash-Hex ([Text.Encoding]::UTF8.GetBytes($canonical)))"
            $signingKey = Hmac ([Text.Encoding]::UTF8.GetBytes('AWS4' + $script:secret)) $day
            $signingKey = Hmac $signingKey 'us-east-1'; $signingKey = Hmac $signingKey 's3'; $signingKey = Hmac $signingKey 'aws4_request'
            $signature = [Convert]::ToHexString((Hmac $signingKey $toSign)).ToLowerInvariant()
            foreach ($header in $signed.GetEnumerator()) {
                if ($header.Key -notin @('host', 'content-type')) { [void]$request.Headers.TryAddWithoutValidation($header.Key, $header.Value) }
            }
            [void]$request.Headers.TryAddWithoutValidation('Authorization', "AWS4-HMAC-SHA256 Credential=$script:access/$scope, SignedHeaders=$names, Signature=$signature")
        }
        $response = $http.Send($request)
        try {
            $headers = @{}
            foreach ($h in $response.Headers) { $headers[$h.Key.ToLowerInvariant()] = $h.Value -join ', ' }
            foreach ($h in $response.Content.Headers) { $headers[$h.Key.ToLowerInvariant()] = $h.Value -join ', ' }
            return @{ Status = [int]$response.StatusCode; Body = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult(); Headers = $headers }
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}
function Wait-Healthy([string] $Container) {
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        $health = & docker inspect $Container --format '{{.State.Health.Status}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $health -eq 'healthy') { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Storage nao ficou healthy em 90 segundos; inspecione logs com filtragem de segredos.'
}
function Check-Object([string] $Phase, [string] $Base = $script:sourceEndpoint) {
    $read = S3 GET $key -Base $Base
    if ($read.Status -ne 200 -or (Hash-Hex $read.Body) -ne $results.objectSha256) { throw ('Integridade do objeto falhou: ' + $Phase) }
    foreach ($name in @('content-type', 'content-length', 'etag', 'last-modified', 'x-amz-meta-pi213-run', 'x-amz-meta-sha256')) {
        if ($read.Headers[$name] -cne $script:metadata[$name]) { throw ('Metadado divergente em ' + $Phase + ': ' + $name) }
    }
    if ((S3 GET $key -Base $Base -Anonymous).Status -ne 403 -or (S3 GET '/' -Base $Base -Anonymous).Status -ne 403) {
        throw ('Acesso anonimo nao foi recusado: ' + $Phase)
    }
    Pass $Phase 'SHA-256 e seis metadados identicos; objeto e bucket recusam acesso anonimo (403)'
}
function Check-Logs([string] $Container, [string] $Phase) {
    $logs = @(& docker logs $Container 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $logs.Contains($script:access) -or $logs.Contains($script:secret)) { throw 'Falha na verificacao de logs; valores nao exibidos.' }
    Pass $Phase 'Nenhum dos dois valores S3 reais aparece nos logs'
}
function Check-Network([string] $Network, [string] $StoragePath, [string] $CaPath) {
    $env:AWS_ACCESS_KEY_ID = $script:access
    $env:AWS_SECRET_ACCESS_KEY = $script:secret
    Docker-OK @('run', '--rm', '--network', $Network, '--read-only', '--tmpfs', '/data', '--entrypoint', '/bin/sh',
        '--env', 'AWS_ACCESS_KEY_ID', '--env', 'AWS_SECRET_ACCESS_KEY',
        '--mount', ('type=bind,source=' + $StoragePath + ',target=/opt/balaio/storage,readonly'),
        '--mount', ('type=bind,source=' + $CaPath + ',target=/run/seaweedfs/ca.crt,readonly'),
        $script:image, '/opt/balaio/storage/test-network.sh')
}

try {
    Docker-OK @('version', '--format', 'Docker Engine {{.Server.Version}}')
    $config = (& docker compose --profile extended config --format json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Compose invalido.' }
    $service = $config.services.seaweedfs
    $script:image = $service.image
    if ($image -notmatch '^chrislusf/seaweedfs:4\.53@sha256:[a-f0-9]{64}$') { throw 'Este roteiro foi validado para a imagem fixada 4.53; nao usa latest.' }
    $script:access = $service.environment.AWS_ACCESS_KEY_ID
    $script:secret = $service.environment.AWS_SECRET_ACCESS_KEY
    if ([string]::IsNullOrWhiteSpace($access) -or [string]::IsNullOrWhiteSpace($secret)) { throw 'Credenciais S3 ausentes.' }
    $script:sourceEndpoint = 'http://localhost:' + $service.ports[0].published
    $sourceId = & docker compose ps -q seaweedfs
    if (-not $sourceId) { throw 'O storage principal precisa estar em execucao antes do teste.' }
    Wait-Healthy $sourceId
    $source = (& docker inspect $sourceId) | ConvertFrom-Json
    $sourceVolume = @($source.Mounts | Where-Object Destination -eq '/data')[0].Name
    if ($sourceVolume -ne 'balaio-local_seaweedfs-data') { throw 'Volume principal inesperado; interrompido antes das operacoes.' }
    $otherIds = @(& docker compose --profile extended ps -q | Where-Object { $_ -ne $sourceId })
    if ($otherIds.Count -ne 12) { throw 'O roteiro exige os 12 outros containers em execucao.' }
    $otherStates = @(& docker inspect @otherIds | ConvertFrom-Json | ForEach-Object { $_ })
    $protectedPaths = @('.env','secrets/admin.env','secrets/jwt-private.pem','secrets/jwt-public.pem',
        'secrets/seaweedfs/ca.crt','secrets/seaweedfs/tls.crt','secrets/seaweedfs/tls.key','secrets/seaweedfs-ca/ca.key')
    $protectedHashes = @(Get-FileHash $protectedPaths | Select-Object Path, Hash)
    $existingVolumes = @(& docker volume ls --format '{{.Name}}')
    Pass 'baseline' '13 containers saudaveis esperados; volume principal e arquivos protegidos identificados'

    $payload = [Text.Encoding]::UTF8.GetBytes("Balaio PI-213 persistence diagnostic`nrun=$run`nConteudo nao sensivel para verificacao de SHA-256.`n")
    $localFile = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllBytes($localFile, $payload)
    $results.objectSha256 = (Get-FileHash -LiteralPath $localFile).Hash.ToLowerInvariant()
    $put = S3 PUT $key -Body $payload -DiagnosticMetadata
    if ($put.Status -ne 200) { throw 'Upload diagnostico falhou.' }
    $uploaded = $true
    $initial = S3 GET $key
    if ($initial.Status -ne 200 -or (Hash-Hex $initial.Body) -ne $results.objectSha256) { throw 'Download inicial divergente.' }
    $script:metadata = $initial.Headers
    Check-Object 'initial'
    Write-Output ('Object SHA-256: ' + $results.objectSha256)

    Docker-OK @('compose', 'restart', '-t', '60', 'seaweedfs')
    Wait-Healthy $sourceId
    Check-Object 'after-restart'
    Check-Logs $sourceId 'logs-after-restart'
    Docker-OK @('compose', 'up', '-d', '--no-deps', '--force-recreate', 'seaweedfs')
    $newSourceId = & docker compose ps -q seaweedfs
    if ($newSourceId -eq $sourceId) { throw 'A recriacao nao gerou um novo container.' }
    Wait-Healthy $newSourceId
    $mount = @(((& docker inspect $newSourceId) | ConvertFrom-Json).Mounts | Where-Object Destination -eq '/data')[0]
    if ($mount.Name -ne $sourceVolume) { throw 'Volume principal mudou na recriacao.' }
    $sourceId = $newSourceId
    Check-Object 'after-recreate'
    Check-Logs $sourceId 'logs-after-recreate'
    Check-Network $config.networks.default.name (Join-Path $repo 'storage') (Join-Path $repo 'secrets/seaweedfs/ca.crt')
    Pass 'security-after-recreate' 'S3 autenticado, mTLS e isolamento administrativo verificados a partir de outro container'

    & git check-ignore --quiet -- (Join-Path $backup 'data.tar.gz')
    if ($LASTEXITCODE -ne 0) { throw 'Backup nao protegido por Git ignore.' }
    if (Test-Path -LiteralPath $backup) { throw 'Backup de destino ja existe; nao sera sobrescrito.' }
    New-Item -ItemType Directory -Path $backup | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $backup -AclObject $acl

    Docker-OK @('compose','stop','-t','60','seaweedfs')
    $stoppedSource = $true
    $stopped = (& docker inspect $sourceId) | ConvertFrom-Json
    if ($stopped.State.Running -or $stopped.State.ExitCode -ne 0) { throw 'Parada nao foi limpa; backup consistente nao sera declarado.' }
    try {
        New-Item -ItemType Directory -Path (Join-Path $backup 'config/secrets/seaweedfs'),(Join-Path $backup 'config/secrets/seaweedfs-ca') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'storage') -Destination (Join-Path $backup 'config/storage') -Recurse
        foreach ($name in @('ca.crt','tls.crt','tls.key')) {
            Copy-Item -LiteralPath (Join-Path $repo ('secrets/seaweedfs/'+$name)) -Destination (Join-Path $backup ('config/secrets/seaweedfs/'+$name))
        }
        Copy-Item -LiteralPath (Join-Path $repo 'secrets/seaweedfs-ca/ca.key') -Destination (Join-Path $backup 'config/secrets/seaweedfs-ca/ca.key')
        @{accessKey=$access; secretKey=$secret} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'config/s3-credentials.json') -Encoding utf8NoBOM
        $archiveCommand = 'set -eu; cd /source; find . -type f -exec sha256sum {} \; | sort > /backup/volume-files.sha256; tar -czf /backup/data.tar.gz -C /source .; tar -tzf /backup/data.tar.gz >/dev/null'
        Docker-OK @('run','--rm','--network','none','--read-only','--tmpfs','/data','--entrypoint','/bin/sh',
            '--mount',('type=volume,source='+$sourceVolume+',target=/source,readonly'),
            '--mount',('type=bind,source='+$backup+',target=/backup'),$image,'-c',$archiveCommand)
        $results.archiveSha256 = (Get-FileHash (Join-Path $backup 'data.tar.gz')).Hash.ToLowerInvariant()
        $results.volumeFileCount = @(Get-Content (Join-Path $backup 'volume-files.sha256')).Count
        if ($results.volumeFileCount -lt 1) { throw 'Backup vazio.' }
        $configHashes = @(Get-ChildItem (Join-Path $backup 'config') -Recurse -File | ForEach-Object {
            [ordered]@{path=[IO.Path]::GetRelativePath($backup,$_.FullName);sha256=(Get-FileHash $_.FullName).Hash}
        })
        $results.configHashes = $configHashes
        Pass 'consistent-backup' ('Storage parado com exit 0; arquivo tar validado; '+$results.volumeFileCount+' arquivos inventariados')
    } finally {
        Docker-OK @('compose','start','seaweedfs')
        $stoppedSource = $false
        Wait-Healthy $sourceId
    }
    Check-Object 'after-backup'

    # A new named volume is mandatory. Never extract into an existing volume.
    if ($existingVolumes -contains $restoreVolume) { throw 'Volume isolado ja existe.' }
    $null = & docker volume inspect $restoreVolume 2>$null
    if ($LASTEXITCODE -eq 0) { throw 'Volume isolado ja existe; recusa sobrescrever.' }
    Docker-OK @('volume','create','--label','balaio.validation=pi213-step5',$restoreVolume)
    if ((Get-FileHash (Join-Path $backup 'data.tar.gz')).Hash.ToLowerInvariant() -ne $results.archiveSha256) { throw 'Hash do arquivo de backup mudou.' }
    $extractCommand = 'set -eu; test -z "$(ls -A /restore)"; tar -xzf /backup/data.tar.gz -C /restore; cd /restore; sha256sum -c /backup/volume-files.sha256 >/dev/null'
    Docker-OK @('run','--rm','--network','none','--read-only','--tmpfs','/data','--entrypoint','/bin/sh',
        '--mount',('type=volume,source='+$restoreVolume+',target=/restore'),
        '--mount',('type=bind,source='+$backup+',target=/backup,readonly'),$image,'-c',$extractCommand)
    Pass 'full-volume-restore' 'Restauracao em volume novo; SHA-256 de todos os arquivos confere antes de iniciar o storage'

    $restoreService = [ordered]@{
        image=$image; restart='no'; working_dir='/etc/seaweedfs'; entrypoint=$service.entrypoint; command=$service.command
        tmpfs=@('/tmp'); environment=@{
            AWS_ACCESS_KEY_ID='${PI213_RESTORE_ACCESS:?Restore credentials missing}'
            AWS_SECRET_ACCESS_KEY='${PI213_RESTORE_SECRET:?Restore credentials missing}'
            S3_BUCKET='balaio-media'
        }
        ports=@(@{target=8333;published='0';host_ip='127.0.0.1';protocol='tcp'})
        volumes=@(
            @{type='volume';source='restored-data';target='/data'},
            @{type='bind';source=(Join-Path $backup 'config/storage');target='/opt/balaio/storage';read_only=$true;bind=@{create_host_path=$false}},
            @{type='bind';source=(Join-Path $backup 'config/storage/security.toml');target='/etc/seaweedfs/security.toml';read_only=$true;bind=@{create_host_path=$false}},
            @{type='bind';source=(Join-Path $backup 'config/secrets/seaweedfs');target='/run/seaweedfs';read_only=$true;bind=@{create_host_path=$false}}
        ); healthcheck=$service.healthcheck; labels=@{'balaio.validation'='pi213-step5'}
    }
    @{services=@{seaweedfs=$restoreService};volumes=@{'restored-data'=@{external=$true;name=$restoreVolume}}} |
        ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $composeFile -Encoding utf8NoBOM
    $credentials = Get-Content (Join-Path $backup 'config/s3-credentials.json') -Raw | ConvertFrom-Json
    $env:PI213_RESTORE_ACCESS = $credentials.accessKey
    $env:PI213_RESTORE_SECRET = $credentials.secretKey
    Docker-OK @('compose','-p',$project,'-f',$composeFile,'config','--quiet')
    $restoreStarted = $true
    Docker-OK @('compose','-p',$project,'-f',$composeFile,'up','-d','--no-deps','seaweedfs')
    $restoreId = & docker compose -p $project -f $composeFile ps -q seaweedfs
    Wait-Healthy $restoreId
    $restored = (& docker inspect $restoreId) | ConvertFrom-Json
    $restoreMount = @($restored.Mounts | Where-Object Destination -eq '/data')[0].Name
    if ($restoreMount -ne $restoreVolume -or $restoreMount -eq $sourceVolume) { throw 'Isolamento do volume restaurado falhou.' }
    $published = $restored.NetworkSettings.Ports.'8333/tcp'[0]
    if ($published.HostIp -ne '127.0.0.1') { throw 'Bind do teste nao e loopback.' }
    $restoreEndpoint = 'http://127.0.0.1:' + $published.HostPort
    $results.restoreEndpoint = $restoreEndpoint
    Check-Object 'restored-object' $restoreEndpoint
    Check-Logs $restoreId 'restored-logs'
    Docker-OK @('exec',$restoreId,'weed','version')
    $restoreConfig = (& docker compose -p $project -f $composeFile config --format json) | ConvertFrom-Json
    Check-Network $restoreConfig.networks.default.name (Join-Path $backup 'config/storage') (Join-Path $backup 'config/secrets/seaweedfs/ca.crt')
    Pass 'restored-security' 'Imagem e configuracao do snapshot; credenciais/certificados recuperados; S3 privado e mTLS verificados'

    foreach ($entry in $protectedHashes) {
        if ((Get-FileHash -LiteralPath $entry.Path).Hash -ne $entry.Hash) { throw 'Arquivo principal protegido foi modificado.' }
    }
    foreach ($old in $otherStates) {
        $now = (& docker inspect $old.Id) | ConvertFrom-Json
        if (-not $now.State.Running -or $now.State.Health.Status -ne 'healthy' -or $now.State.StartedAt -ne $old.State.StartedAt) {
            throw 'Um dos 12 containers anteriores foi alterado ou nao esta saudavel.'
        }
    }
    $remainingVolumes = @(& docker volume ls --format '{{.Name}}')
    foreach ($v in $existingVolumes) { if ($remainingVolumes -notcontains $v) { throw 'Volume anterior ausente.' } }
    Pass 'preserved-environment' '12 containers com IDs e StartedAt preservados; segredos/certificados/.env identicos; nenhum volume anterior removido'
    $complete = $true
} finally {
    if ($stoppedSource) {
        & docker compose start seaweedfs
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Storage principal nao reiniciou; verificar Docker e iniciar somente seaweedfs.' }
    }
    if ($restoreStarted) {
        & docker compose -p $project -f $composeFile stop -t 60 seaweedfs
        if ($LASTEXITCODE -eq 0) { $results.restoreFinalState = 'stopped; container, network and volume retained' }
    }
    if ($uploaded) {
        try {
            $deleted = S3 DELETE $key
            if ($deleted.Status -eq 204) { Pass 'diagnostic-cleanup' 'Somente o objeto criado neste teste foi removido do storage principal; backup/restauracao preservam a evidencia' }
            else { Write-Warning 'Objeto diagnostico preservado; limpeza nao confirmada.' }
        } catch { Write-Warning 'Objeto diagnostico pode permanecer; nenhuma outra chave foi removida.' }
    }
    $results.completed = $complete
    $results.finishedUtc = [DateTime]::UtcNow.ToString('o')
    if (Test-Path -LiteralPath $backup -PathType Container) {
        $results | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding utf8NoBOM
    }
    [Environment]::SetEnvironmentVariable('PI213_RESTORE_ACCESS',$savedAccess)
    [Environment]::SetEnvironmentVariable('PI213_RESTORE_SECRET',$savedSecret)
    [Environment]::SetEnvironmentVariable('AWS_ACCESS_KEY_ID',$oldAwsAccess)
    [Environment]::SetEnvironmentVariable('AWS_SECRET_ACCESS_KEY',$oldAwsSecret)
    if ($localFile -and (Test-Path -LiteralPath $localFile -PathType Leaf)) { Remove-Item -LiteralPath $localFile }
    $http.Dispose()
    Pop-Location
}
Write-Output ('Backup e evidencias protegidos: ' + $backup)
Write-Output ('Projeto isolado parado, volume preservado: ' + $project)
