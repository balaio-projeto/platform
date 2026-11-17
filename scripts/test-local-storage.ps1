param([switch] $IncludeSpecialCharacterTest)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.2') { throw 'Requer PowerShell 7.2 ou superior.' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $repo
$client = [Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(15)
$oldAccess = [Environment]::GetEnvironmentVariable('AWS_ACCESS_KEY_ID')
$oldSecret = [Environment]::GetEnvironmentVariable('AWS_SECRET_ACCESS_KEY')
try {
    $configText = & docker compose config --format json
    if ($LASTEXITCODE -ne 0) { throw 'Compose invalido. Execute setup-local.ps1.' }
    $config = $configText | ConvertFrom-Json
    $access = $config.services.seaweedfs.environment.AWS_ACCESS_KEY_ID
    $secret = $config.services.seaweedfs.environment.AWS_SECRET_ACCESS_KEY
    $port = $config.services.seaweedfs.ports[0].published
    $image = $config.services.seaweedfs.image
    $endpoint = "http://localhost:$port"
    $healthy = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $health = & docker inspect balaio-local-seaweedfs-1 --format '{{.State.Health.Status}}'
        if ($health -eq 'healthy') { $healthy = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $healthy) { throw 'Storage nao ficou healthy em 60 segundos. Inspecione logs sem divulgar segredos.' }
    Write-Output 'CT-04/05 PASS: SeaweedFS running and healthy'

    function Hash-Hex([byte[]] $Bytes) {
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    }
    function Hmac([byte[]] $Key, [string] $Text) {
        return ,([Security.Cryptography.HMACSHA256]::HashData($Key, [Text.Encoding]::UTF8.GetBytes($Text)))
    }
    function Request-S3([string] $Method, [string] $Path, [byte[]] $Payload = @(), [switch] $Anonymous) {
        $uri = [Uri]::new($endpoint + $Path)
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $uri)
        try {
            if ($Method -eq 'PUT') { $request.Content = [Net.Http.ByteArrayContent]::new($Payload) }
            if (-not $Anonymous) {
                $date = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
                $day = $date.Substring(0, 8)
                $payloadHash = Hash-Hex $Payload
                $headers = "host:$($uri.Authority)`nx-amz-content-sha256:$payloadHash`nx-amz-date:$date`n"
                $names = 'host;x-amz-content-sha256;x-amz-date'
                $canonical = "$Method`n$Path`n`n$headers`n$names`n$payloadHash"
                $scope = "$day/us-east-1/s3/aws4_request"
                $toSign = "AWS4-HMAC-SHA256`n$date`n$scope`n$(Hash-Hex ([Text.Encoding]::UTF8.GetBytes($canonical)))"
                $key = Hmac ([Text.Encoding]::UTF8.GetBytes('AWS4' + $secret)) $day
                $key = Hmac $key 'us-east-1'; $key = Hmac $key 's3'; $key = Hmac $key 'aws4_request'
                $signature = [Convert]::ToHexString((Hmac $key $toSign)).ToLowerInvariant()
                [void]$request.Headers.TryAddWithoutValidation('x-amz-date', $date)
                [void]$request.Headers.TryAddWithoutValidation('x-amz-content-sha256', $payloadHash)
                [void]$request.Headers.TryAddWithoutValidation('Authorization',
                    "AWS4-HMAC-SHA256 Credential=$access/$scope, SignedHeaders=$names, Signature=$signature")
            }
            $response = $client.Send($request)
            try { return @{ Status = [int]$response.StatusCode; Body = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() } }
            finally { $response.Dispose() }
        } finally { $request.Dispose() }
    }
    function Require([bool] $Condition, [string] $Message) {
        if (-not $Condition) { throw ($Message -replace ' PASS:', ' FAIL:') }
        Write-Output $Message
    }

    $root = Request-S3 GET '/'
    Require ($root.Status -eq 200) 'CT-06/09 PASS: signed ListBuckets via localhost returns HTTP 200'
    $anonymous = Request-S3 GET '/' -Anonymous
    Require ($anonymous.Status -eq 403) 'CT-07 PASS: anonymous ListBuckets returns HTTP 403'
    $bucket = Request-S3 HEAD '/balaio-media'
    Require ($bucket.Status -eq 200) 'CT-08 PASS: private balaio-media bucket exists'
    $key = '/balaio-media/diagnostics/pi213-' + [Guid]::NewGuid().ToString('N') + '.txt'
    $payload = [Text.Encoding]::UTF8.GetBytes('Balaio PI-213 non-sensitive S3 smoke test')
    $uploaded = $false
    try {
        $put = Request-S3 PUT $key $payload
        Require ($put.Status -eq 200) 'S3 PUT PASS: temporary non-sensitive object uploaded'
        $uploaded = $true
        $get = Request-S3 GET $key
        Require ($get.Status -eq 200 -and (Hash-Hex $get.Body) -eq (Hash-Hex $payload)) 'S3 GET PASS: downloaded content hash matches'
        $denied = Request-S3 GET $key -Anonymous
        Require ($denied.Status -eq 403) 'Private object PASS: anonymous GET denied'
    } finally {
        if ($uploaded) {
            $deleted = Request-S3 DELETE $key
            Require ($deleted.Status -eq 204) 'Cleanup PASS: removed only the uniquely named diagnostic object'
        }
    }

    $env:AWS_ACCESS_KEY_ID = $access
    $env:AWS_SECRET_ACCESS_KEY = $secret
    $mount = 'type=bind,source=' + (Join-Path $repo 'storage') + ',target=/opt/balaio/storage,readonly'
    $caMount = 'type=bind,source=' + (Join-Path $repo 'secrets/seaweedfs/ca.crt') + ',target=/run/seaweedfs/ca.crt,readonly'
    $network = @($config.networks.PSObject.Properties | Where-Object Name -eq 'default')[0].Value.name
    & docker run --rm --network $network --read-only --tmpfs /data --entrypoint /bin/sh `
        --env AWS_ACCESS_KEY_ID --env AWS_SECRET_ACCESS_KEY --mount $mount --mount $caMount `
        $image /opt/balaio/storage/test-network.sh
    if ($LASTEXITCODE -ne 0) { throw 'Network security test failed.' }

    $logs = @(& docker logs balaio-local-seaweedfs-1 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    Require (-not ($logs.Contains($access) -or $logs.Contains($secret))) 'Logs PASS: neither actual S3 credential value appears'

    if ($IncludeSpecialCharacterTest) {
        # Isolated fixture: no network, no host ports and no Docker data volume.
        $testName = 'balaio-storage-ct14-' + [Guid]::NewGuid().ToString('N').Substring(0, 10)
        $env:AWS_ACCESS_KEY_ID = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
        $env:AWS_SECRET_ACCESS_KEY = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) + ' +/=:"\$# special'
        $certMount = 'type=bind,source=' + (Join-Path $repo 'secrets/seaweedfs') + ',target=/run/seaweedfs,readonly'
        $securityMount = 'type=bind,source=' + (Join-Path $repo 'storage/security.toml') + ',target=/etc/seaweedfs/security.toml,readonly'
        try {
            $null = & docker run -d --name $testName --label balaio.test=pi213-ct14 --network none `
                --tmpfs /data --tmpfs /tmp --workdir /etc/seaweedfs --entrypoint /bin/sh `
                --env AWS_ACCESS_KEY_ID --env AWS_SECRET_ACCESS_KEY --env S3_BUCKET=balaio-media `
                --mount $mount --mount $certMount --mount $securityMount $image /opt/balaio/storage/start.sh `
                mini '-dir=/data' '-ip=127.0.0.1' '-ip.bind=127.0.0.1' '-s3.port=8333' '-webdav=false' `
                '-admin.ui=true' '-admin.port.legacy=0' '-s3.port.iceberg=0' '-s3.port.lance=0'
            if ($LASTEXITCODE -ne 0) { throw 'CT-14 fixture could not start.' }
            $ready = $false
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                & docker exec $testName /bin/sh /opt/balaio/storage/healthcheck.sh
                if ($LASTEXITCODE -eq 0) { $ready = $true; break }
                Start-Sleep -Seconds 2
            }
            if (-not $ready) {
                $diagnostic = @(& docker logs $testName 2>&1 | ForEach-Object { $_.ToString() })
                $diagnostic | Where-Object { $_ -match '(?i)error|fail|bucket|denied' } | Select-Object -Last 10 |
                    ForEach-Object { $_.Replace($env:AWS_ACCESS_KEY_ID, '[REDACTED]').Replace($env:AWS_SECRET_ACCESS_KEY, '[REDACTED]') }
            }
            Require $ready 'CT-14 PASS: real signed healthcheck accepts spaces, quotes, backslash, dollar, hash, slash, plus, equals and colon'
            $testLogs = @(& docker logs $testName 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
            Require (-not ($testLogs.Contains($env:AWS_ACCESS_KEY_ID) -or $testLogs.Contains($env:AWS_SECRET_ACCESS_KEY))) 'CT-14 PASS: special credentials absent from logs'
        } finally {
            # Remove ONLY the named disposable fixture with its expected label.
            $label = & docker inspect $testName --format '{{index .Config.Labels "balaio.test"}}' 2>$null
            if ($LASTEXITCODE -eq 0 -and $label -eq 'pi213-ct14') {
                $null = & docker stop -t 10 $testName
                $null = & docker rm $testName
            }
        }
    }
} finally {
    [Environment]::SetEnvironmentVariable('AWS_ACCESS_KEY_ID', $oldAccess)
    [Environment]::SetEnvironmentVariable('AWS_SECRET_ACCESS_KEY', $oldSecret)
    $client.Dispose()
    Pop-Location
}
