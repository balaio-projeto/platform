param([string] $EnvFile = (Join-Path $PSScriptRoot '..\.env'), [switch] $Enable)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$EnvFile = [IO.Path]::GetFullPath($EnvFile)
& git -C $repo check-ignore --quiet -- $EnvFile
if ($LASTEXITCODE -ne 0) { throw 'Arquivo de segredos deve estar ignorado pelo Git.' }
& git -C $repo ls-files --error-unmatch -- $EnvFile 2>$null 1>$null
if ($LASTEXITCODE -eq 0) { throw 'Arquivo de segredos rastreado pelo Git.' }
$original = if (Test-Path -LiteralPath $EnvFile) { [IO.File]::ReadAllText($EnvFile) } else { '' }
$updated = $original
function Read-Value([string] $Name) {
    $matchesFound = [regex]::Matches($original, "(?m)^$Name=([^\r\n]*)")
    if ($matchesFound.Count -gt 1) { throw 'Variavel duplicada no .env.' }
    if ($matchesFound.Count -eq 0) { return '' }
    return $matchesFound[0].Groups[1].Value.Trim("'")
}
$access = Read-Value 'CATALOG_S3_ACCESS_KEY_ID'
$secret = Read-Value 'CATALOG_S3_SECRET_ACCESS_KEY'
if ([bool]$access -xor [bool]$secret) { throw 'Par de credenciais do catalogo incompleto; valores preservados.' }
if (-not $access) {
    $access = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $secret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
}
if ($access -notmatch '^[A-Za-z0-9_-]{20,128}$' -or $secret -notmatch '^[A-Za-z0-9_-]{40,256}$') {
    throw 'Credenciais de catalogo invalidas; use tokens aleatorios alfanumericos.'
}
if ($access -eq (Read-Value 'S3_ACCESS_KEY_ID') -or $secret -eq (Read-Value 'S3_SECRET_ACCESS_KEY')) {
    throw 'O catalogo nao pode usar as credenciais administrativas.'
}
$entries = @{ CATALOG_S3_ACCESS_KEY_ID = $access; CATALOG_S3_SECRET_ACCESS_KEY = $secret }
if ($Enable) {
    $entries.CATALOG_S3_ENABLED = 'true'
    $profiles = @((Read-Value 'COMPOSE_PROFILES').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($profiles -notcontains 'storage') { $profiles += 'storage' }
    $entries.COMPOSE_PROFILES = $profiles -join ','
}
foreach ($entry in $entries.GetEnumerator()) {
    $pattern = '(?m)^' + $entry.Key + '=[^\r\n]*'
    $line = $entry.Key + '=' + $entry.Value
    if ([regex]::Matches($updated, $pattern).Count -gt 1) { throw 'Variavel duplicada; configuracao preservada.' }
    if ($updated -match $pattern) { $updated = [regex]::Replace($updated, $pattern, $line) }
    else { $updated = $updated.TrimEnd("`r", "`n") + "`r`n" + $line + "`r`n" }
}
$current = if (Test-Path -LiteralPath $EnvFile) { [IO.File]::ReadAllText($EnvFile) } else { '' }
if ($current -cne $original) { throw 'O .env mudou durante o provisionamento.' }
if ($updated -cne $original) { [IO.File]::WriteAllText($EnvFile, $updated, [Text.UTF8Encoding]::new($false)) }
Write-Output 'Identidade balaio-catalog preparada; credenciais preservadas/geradas sem exibir valores.'
