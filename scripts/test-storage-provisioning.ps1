$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.2' -or -not $IsWindows) { throw 'Requer PowerShell 7.2+ no Windows.' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot = Join-Path $repo ('secrets/pi214-provision-' + [Guid]::NewGuid().ToString('N'))
$envFile = Join-Path $fixtureRoot '.env'
$prepare = Join-Path $PSScriptRoot 'prepare-local-storage.ps1'
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
try {
    $template = [IO.File]::ReadAllText((Join-Path $repo '.env.example'))
    [IO.File]::WriteAllText($envFile, $template, [Text.UTF8Encoding]::new($false))
    & $prepare -EnvFile $envFile -SecretsDirectory (Join-Path $fixtureRoot 'secrets')
    $valid = [IO.File]::ReadAllText($envFile)
    if ($valid -notmatch '(?m)^MEDIA_S3_ENDPOINT=http://seaweedfs:8333\r?$') {
        throw 'Preparador nao habilitou o endpoint do Profile Service.'
    }
    $pairs = @{}
    foreach ($key in @('S3_ACCESS_KEY_ID', 'S3_SECRET_ACCESS_KEY', 'MEDIA_S3_ACCESS_KEY_ID', 'MEDIA_S3_SECRET_ACCESS_KEY')) {
        $match = [regex]::Match($valid, '(?m)^' + $key + '=([^\r\n]+)')
        if (-not $match.Success) { throw 'Credencial nao gerada na instalacao nova.' }
        $pairs[$key] = $match.Groups[1].Value
    }
    if ($pairs.S3_ACCESS_KEY_ID -ceq $pairs.MEDIA_S3_ACCESS_KEY_ID -or
            $pairs.S3_SECRET_ACCESS_KEY -ceq $pairs.MEDIA_S3_SECRET_ACCESS_KEY) { throw 'Pares iguais.' }
    Write-Output 'PASS: instalacao nova gera dois pares independentes'
    $hashes = @(Get-ChildItem $fixtureRoot -Recurse -Force -File | ForEach-Object {
        @{path=$_.FullName;hash=(Get-FileHash -LiteralPath $_.FullName).Hash}
    })
    & $prepare -EnvFile $envFile -SecretsDirectory (Join-Path $fixtureRoot 'secrets')
    foreach ($entry in $hashes) {
        if ((Get-FileHash -LiteralPath $entry.path).Hash -ne $entry.hash) { throw 'Repeticao alterou arquivo existente.' }
    }
    Write-Output 'PASS: repeticao preserva env e certificados byte a byte'
    $customEndpoint = $valid.Replace('MEDIA_S3_ENDPOINT=http://seaweedfs:8333', 'MEDIA_S3_ENDPOINT=http://storage.local:8333')
    [IO.File]::WriteAllText($envFile, $customEndpoint, [Text.UTF8Encoding]::new($false))
    & $prepare -EnvFile $envFile -SecretsDirectory (Join-Path $fixtureRoot 'secrets')
    if ([IO.File]::ReadAllText($envFile) -cne $customEndpoint) { throw 'Endpoint existente foi sobrescrito.' }
    Write-Output 'PASS: endpoint configurado pelo usuario preservado'
    $legacy = [regex]::Replace($valid, '(?m)^MEDIA_S3_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)=[^\r\n]*\r?\n?', '')
    [IO.File]::WriteAllText($envFile, $legacy, [Text.UTF8Encoding]::new($false))
    & $prepare -EnvFile $envFile -SecretsDirectory (Join-Path $fixtureRoot 'secrets')
    $migrated = [IO.File]::ReadAllText($envFile)
    foreach ($key in @('S3_ACCESS_KEY_ID','S3_SECRET_ACCESS_KEY')) {
        if (-not $migrated.Contains($key+'='+$pairs[$key])) { throw 'Credencial administrativa alterada.' }
    }
    Write-Output 'PASS: instalacao PI-213 recebe somente o novo par consumidor'
    $invalidCases = @(
        ($valid + "`nMEDIA_S3_ENDPOINT=http://duplicado.invalid:8333`n"),
        [regex]::Replace($valid, '(?m)^MEDIA_S3_SECRET_ACCESS_KEY=[^\r\n]*', 'MEDIA_S3_SECRET_ACCESS_KEY='),
        [regex]::Replace($valid, '(?m)^MEDIA_S3_ACCESS_KEY_ID=[^\r\n]*', 'MEDIA_S3_ACCESS_KEY_ID=short'),
        ($valid + "`nMEDIA_S3_ACCESS_KEY_ID=duplicate`n"),
        [regex]::Replace($valid, '(?m)^MEDIA_S3_ACCESS_KEY_ID=[^\r\n]*', 'MEDIA_S3_ACCESS_KEY_ID='+$pairs.S3_ACCESS_KEY_ID)
    )
    foreach ($invalid in $invalidCases) {
        [IO.File]::WriteAllText($envFile, $invalid, [Text.UTF8Encoding]::new($false))
        $before = (Get-FileHash -LiteralPath $envFile).Hash
        $rejected = $false
        try { & $prepare -EnvFile $envFile -SecretsDirectory (Join-Path $fixtureRoot 'secrets') } catch { $rejected = $true }
        if (-not $rejected -or (Get-FileHash -LiteralPath $envFile).Hash -ne $before) {
            throw 'Configuracao invalida aceita ou sobrescrita.'
        }
    }
    Write-Output 'PASS: par parcial, invalido, duplicado e reutilizacao administrativa recusados sem sobrescrever'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $expectedParent = [IO.Path]::GetFullPath((Join-Path $repo 'secrets')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path $resolved -Leaf) -notmatch '^pi214-provision-[a-f0-9]{32}$') { throw 'Limpeza da fixture recusada.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
exit 0
