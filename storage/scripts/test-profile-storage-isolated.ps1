$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$taskName = 'pi214-policy-' + [Guid]::NewGuid().ToString('N')
$taskImage = 'chrislusf/seaweedfs:4.53@sha256:ccad23e18639c8b98cee17e7100b95830a06077b56d8e5b006d6dcf8ec5e94a0'
$taskStorage = (Resolve-Path (Join-Path $repo 'storage')).Path
$taskTls = (Resolve-Path (Join-Path $repo 'secrets/seaweedfs')).Path
$taskVars = @('AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','MEDIA_S3_ACCESS_KEY_ID','MEDIA_S3_SECRET_ACCESS_KEY','S3_BUCKET','MEDIA_S3_ENDPOINT')
$taskSaved = @{}
foreach ($taskVar in $taskVars) { $taskSaved[$taskVar] = [Environment]::GetEnvironmentVariable($taskVar) }
Push-Location $repo
try {
 $taskRefusal = & docker run --rm --network none --read-only --tmpfs /data --tmpfs /tmp --entrypoint /bin/sh --env AWS_ACCESS_KEY_ID= --env AWS_SECRET_ACCESS_KEY= --mount "type=bind,source=$taskStorage,target=/opt/balaio/storage,readonly" $taskImage /opt/balaio/storage/start.sh mini -dir=/data 2>&1 | Out-String
 if ($LASTEXITCODE -eq 0 -or $taskRefusal -notmatch 'SeaweedFS bloqueado:') { throw 'Fixture sem credenciais nao apresentou a recusa esperada.' }
 Write-Output 'PASS: inicializacao sem credenciais recusada, sem modo anonimo'
 $env:AWS_ACCESS_KEY_ID = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
 $env:AWS_SECRET_ACCESS_KEY = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
 $env:MEDIA_S3_ACCESS_KEY_ID = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
 $env:MEDIA_S3_SECRET_ACCESS_KEY = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
 $env:S3_BUCKET = 'balaio-media'
 $env:MEDIA_S3_ENDPOINT = 'http://127.0.0.1:8333'
 $taskArgs = @('run','-d','--name',$taskName,'--label','balaio.validation=pi214-isolated-policy','--network','none','--read-only','--tmpfs','/data','--tmpfs','/tmp','--workdir','/etc/seaweedfs',
 '--mount',"type=bind,source=$taskStorage,target=/opt/balaio/storage,readonly",'--mount',"type=bind,source=$taskStorage/security.toml,target=/etc/seaweedfs/security.toml,readonly",'--mount',"type=bind,source=$taskTls,target=/run/seaweedfs,readonly",'--entrypoint','/bin/sh')
 foreach ($taskVar in $taskVars) { $taskArgs += @('--env',$taskVar) }
 $taskArgs += @($taskImage,'/opt/balaio/storage/start.sh','mini','-dir=/data','-ip=127.0.0.1','-ip.bind=127.0.0.1','-s3.port=8333','-s3.iam.readOnly=true','-s3.port.iceberg=0','-s3.port.lance=0','-webdav=false','-admin.port.legacy=0','-admin.worker.ip=127.0.0.1')
 $taskId = & docker @taskArgs
 if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel criar fixture S3 isolada.' }
 $taskHealthy = $false
 for ($taskAttempt = 0; $taskAttempt -lt 35; $taskAttempt++) {
  & docker exec $taskName /bin/sh /opt/balaio/storage/healthcheck.sh *> $null
  if ($LASTEXITCODE -eq 0) { $taskHealthy = $true; break }
  Start-Sleep -Seconds 2
 }
 if (-not $taskHealthy) { throw 'Fixture S3 nao ficou pronta. Logs nao foram exibidos para proteger credenciais.' }
 Write-Output 'PASS: readiness S3 autenticado e recusa anonima em fixture tmpfs'
 & docker exec $taskName /bin/sh /opt/balaio/storage/test-profile-access.sh
 if ($LASTEXITCODE -ne 0) { throw 'Politica S3 restrita falhou.' }
 $taskLogs = (& docker logs $taskName 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
 foreach ($taskVar in $taskVars | Select-Object -First 4) {
  if ($taskLogs.Contains([Environment]::GetEnvironmentVariable($taskVar))) { throw 'Credencial identificada nos logs; valores omitidos.' }
 }
 Write-Output 'PASS: nenhuma das quatro credenciais aleatorias aparece nos logs'
} finally {
 $taskLabel = & docker inspect $taskName --format '{{index .Config.Labels "balaio.validation"}}' 2>$null
 if ($LASTEXITCODE -eq 0 -and $taskLabel -eq 'pi214-isolated-policy') { & docker rm -f $taskName | Out-Null }
 foreach ($taskVar in $taskVars) { [Environment]::SetEnvironmentVariable($taskVar, $taskSaved[$taskVar]) }
 Pop-Location
}
