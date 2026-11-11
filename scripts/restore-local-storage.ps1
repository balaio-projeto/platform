param([Parameter(Mandatory = $true)][string] $BackupDirectory)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.2' -or -not $IsWindows) { throw 'Requer PowerShell 7.2+ no Windows.' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$backup = (Resolve-Path -LiteralPath $BackupDirectory).Path
$manifest = Get-Content -LiteralPath (Join-Path $backup 'manifest.json') -Raw | ConvertFrom-Json
if (-not $manifest.completed) { throw 'O manifesto nao registra uma validacao completa; investigar antes de restaurar.' }
$template = Get-Content -LiteralPath (Join-Path $backup 'restore.compose.json') -Raw | ConvertFrom-Json
$image = $template.services.seaweedfs.image
if ($image -notmatch '^chrislusf/seaweedfs:4\.53@sha256:[a-f0-9]{64}$') { throw 'Versao/digest inesperado; nao sera feita atualizacao automatica.' }
if ($manifest.objectPath -notmatch '^/balaio-media/diagnostics/pi213-persistence-[a-f0-9]{32}\.txt$') { throw 'Caminho diagnostico inesperado no manifesto.' }
if ((Get-FileHash -LiteralPath (Join-Path $backup 'data.tar.gz')).Hash.ToLowerInvariant() -ne $manifest.archiveSha256) {
    throw 'Backup com SHA-256 divergente; nada foi restaurado.'
}
foreach ($entry in $manifest.configHashes) {
    $file = [IO.Path]::GetFullPath((Join-Path $backup $entry.path))
    if (-not $file.StartsWith($backup.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Caminho de configuracao fora do backup.'
    }
    if ((Get-FileHash -LiteralPath $file).Hash -ne $entry.sha256) { throw 'Configuracao/certificado do snapshot com hash divergente.' }
}
try {
    $credentials = Get-Content -LiteralPath (Join-Path $backup 'config/s3-credentials.json') -Raw | ConvertFrom-Json
} catch { throw 'Arquivo de credenciais do snapshot invalido; valores nao exibidos.' }
if ([string]::IsNullOrWhiteSpace($credentials.accessKey) -or [string]::IsNullOrWhiteSpace($credentials.secretKey)) { throw 'Credenciais do snapshot incompletas.' }
$id = [Guid]::NewGuid().ToString('N').Substring(0,12)
$project = 'balaio-storage-recovery-' + $id
$volume = $project + '-data'
$session = Join-Path $repo ('backups/restore-session-' + $id)
$compose = Join-Path $session 'restore.compose.json'
$emptyEnv = Join-Path $session 'empty.env'
$saved = @{}
foreach ($name in @('PI213_RESTORE_ACCESS','PI213_RESTORE_SECRET','PI213_RECOVERY_PATH','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$started = $false
$report = [ordered]@{backup=$backup;project=$project;volume=$volume;completed=$false}
function Docker-OK([string[]] $Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Operacao Docker de restauracao falhou; segredo nao exibido.' }
}
try {
    Docker-OK @('version','--format','Docker Engine {{.Server.Version}}')
    & git -C $repo check-ignore --quiet -- $compose
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $session)) { throw 'Destino de sessao existente ou sem Git ignore.' }
    New-Item -ItemType Directory -Path $session | Out-Null
    Set-Acl -LiteralPath $session -AclObject (Get-Acl -LiteralPath $backup)
    # Prevent Compose's automatic discovery of the main working-directory .env.
    [IO.File]::WriteAllText($emptyEnv, '', [Text.UTF8Encoding]::new($false))
    $null = & docker volume inspect $volume 2>$null
    if ($LASTEXITCODE -eq 0) { throw 'Recusa sobrescrever volume existente.' }
    Docker-OK @('volume','create','--label','balaio.validation=pi213-step5',$volume)
    $extract = 'set -eu; test -z "$(ls -A /restore)"; tar -xzf /backup/data.tar.gz -C /restore; cd /restore; sha256sum -c /backup/volume-files.sha256 >/dev/null'
    Docker-OK @('run','--rm','--network','none','--read-only','--tmpfs','/data','--entrypoint','/bin/sh',
        '--mount',('type=volume,source='+$volume+',target=/restore'),
        '--mount',('type=bind,source='+$backup+',target=/backup,readonly'),$image,'-c',$extract)
    Write-Output 'PASS: todos os arquivos restaurados conferem com o inventario SHA-256'

    $template.volumes.'restored-data'.name = $volume
    $template.services.seaweedfs.ports[0].published = '0'
    foreach ($mount in $template.services.seaweedfs.volumes) {
        switch ($mount.target) {
            '/data' { if ($mount.type -ne 'volume' -or $mount.source -ne 'restored-data') { throw 'Mount de dados inesperado.' } }
            '/opt/balaio/storage' { $mount.source = Join-Path $backup 'config/storage' }
            '/etc/seaweedfs/security.toml' { $mount.source = Join-Path $backup 'config/storage/security.toml' }
            '/run/seaweedfs' { $mount.source = Join-Path $backup 'config/secrets/seaweedfs' }
            default { throw 'Mount nao previsto; restauracao recusada.' }
        }
    }
    $template | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $compose -Encoding utf8NoBOM
    $env:PI213_RESTORE_ACCESS = $credentials.accessKey
    $env:PI213_RESTORE_SECRET = $credentials.secretKey
    Docker-OK @('compose','--env-file',$emptyEnv,'-p',$project,'-f',$compose,'config','--quiet')
    $started = $true
    Docker-OK @('compose','--env-file',$emptyEnv,'-p',$project,'-f',$compose,'up','-d','--wait','--wait-timeout','90','seaweedfs')
    $container = & docker compose --env-file $emptyEnv -p $project -f $compose ps -q seaweedfs
    $details = (& docker inspect $container) | ConvertFrom-Json
    if (@($details.Mounts | Where-Object Destination -eq '/data')[0].Name -ne $volume) { throw 'Volume isolado inesperado.' }
    $published = $details.NetworkSettings.Ports.'8333/tcp'[0]
    if ($published.HostIp -ne '127.0.0.1') { throw 'Porta de teste nao esta em loopback.' }
    $report.endpoint = 'http://127.0.0.1:' + $published.HostPort

    $env:PI213_RECOVERY_PATH = $manifest.objectPath
    $probe = @'
set -eu
a=$(printf '%s' "$AWS_ACCESS_KEY_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')
s=$(printf '%s' "$AWS_SECRET_ACCESS_KEY" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf 'user = "%s:%s"\n' "$a" "$s" | curl --config - --noproxy '*' --silent --fail --max-time 10 --aws-sigv4 'aws:amz:us-east-1:s3' --output /tmp/recovered-diagnostic "http://127.0.0.1:8333$PI213_RECOVERY_PATH" 2>/dev/null
sha256sum /tmp/recovered-diagnostic
status=$(curl --noproxy '*' --silent --max-time 3 --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:8333$PI213_RECOVERY_PATH" 2>/dev/null)
[ "$status" = 403 ]
'@
    $hashOutput = @(& docker exec --env PI213_RECOVERY_PATH $container /bin/sh -c $probe)
    if ($LASTEXITCODE -ne 0 -or $hashOutput.Count -ne 1 -or ($hashOutput[0] -split '\s+')[0] -ne $manifest.objectSha256) {
        throw 'Objeto restaurado divergente ou leitura anonima nao recusada.'
    }
    Write-Output 'PASS: objeto restaurado com SHA-256 identico e acesso anonimo recusado (403)'
    $logs = @(& docker logs $container 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    if ($logs.Contains($credentials.accessKey) -or $logs.Contains($credentials.secretKey)) { throw 'Credencial identificada nos logs; valores nao exibidos.' }
    Write-Output 'PASS: credenciais/certificados recuperados somente do snapshot; healthcheck e logs aprovados'
    $report.completed = $true
    $report.objectSha256 = $manifest.objectSha256
} finally {
    if ($started) {
        & docker compose --env-file $emptyEnv -p $project -f $compose stop -t 60 seaweedfs
        if ($LASTEXITCODE -eq 0) { $report.finalState = 'stopped; volume retained' }
    }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path -LiteralPath $session) {
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $session 'restore-result.json') -Encoding utf8NoBOM
    }
}
Write-Output ('Restauracao independente preservada e parada: ' + $project)
