param(
    [string] $EnvFile = (Join-Path $PSScriptRoot '..\.env')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7 -or ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 2)) {
    throw 'prepare-internal-token.ps1 requer PowerShell 7.2 ou superior. Execute o script em um terminal pwsh. O .env nao foi alterado.'
}
if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
    throw "Crie $EnvFile a partir de .env.example antes de preparar o token interno."
}
$conteudo = [System.IO.File]::ReadAllText($EnvFile)
$padrao = '(?m)^BALAIO_INTERNAL_TOKEN=(.*)$'
$encontrado = [regex]::Match($conteudo, $padrao)
$valor = if ($encontrado.Success) { $encontrado.Groups[1].Value.TrimEnd("`r") } else { '' }
if ($encontrado.Success -and $valor.Length -ge 32) {
    Write-Output 'Token interno local válido.'
    return
}
if ($encontrado.Success -and $valor.Length -gt 0) {
    throw 'BALAIO_INTERNAL_TOKEN deve ter pelo menos 32 caracteres; não substituí o valor existente.'
}
$token = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
if ($encontrado.Success) {
    $conteudo = [regex]::Replace($conteudo, $padrao, "BALAIO_INTERNAL_TOKEN=$token")
} else {
    $conteudo = $conteudo.TrimEnd("`r", "`n") + "`r`nBALAIO_INTERNAL_TOKEN=$token`r`n"
}
[System.IO.File]::WriteAllText($EnvFile, $conteudo)
Write-Output 'Token interno local gerado em .env (ignorado pelo Git).'
