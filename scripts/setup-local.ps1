param(
    [string] $EnvFile = (Join-Path $PSScriptRoot '..\.env'),
    [string] $SecretsDirectory = (Join-Path $PSScriptRoot '..\secrets')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7 -or ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 2)) {
    throw 'setup-local.ps1 requer PowerShell 7.2 ou superior. Abra o PowerShell 7 (pwsh) e execute: pwsh -NoProfile -File .\scripts\setup-local.ps1. Nenhum arquivo foi alterado.'
}
$example = Join-Path $PSScriptRoot '..\.env.example'
$novoEnv = $false

if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
    $conteudo = [System.IO.File]::ReadAllText($example)
    $stream = [System.IO.File]::Open($EnvFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
        try {
            $writer.Write($conteudo)
        } finally {
            $writer.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    $novoEnv = $true
    Write-Output "Arquivo .env criado em $EnvFile. Defina sua propria DB_PASSWORD antes do primeiro up."
} else {
    Write-Output "Arquivo .env existente preservado em $EnvFile."
}
$conteudoExistente = [System.IO.File]::ReadAllText($EnvFile)
if ($conteudoExistente -notmatch '(?m)^DB_PASSWORD=[^\r\n]+\r?$') {
    Write-Warning 'DB_PASSWORD ausente ou vazia. Defina uma senha propria no .env, ou preencha todas as senhas individuais exigidas pelo Compose. Nenhuma senha existente foi alterada.'
}

& (Join-Path $PSScriptRoot 'prepare-local-jwt.ps1') -Directory $SecretsDirectory

$adminPath = Join-Path $SecretsDirectory 'admin.env'
if (-not (Test-Path -LiteralPath $adminPath -PathType Leaf)) {
    New-Item -ItemType Directory -Path $SecretsDirectory -Force | Out-Null
    $stream = [System.IO.File]::Open($adminPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
        try {
            $writer.Write("ADMIN_EMAIL=`nADMIN_SENHA_INICIAL=`n")
        } finally {
            $writer.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    Write-Output "Arquivo do administrador criado em $adminPath com duas variaveis vazias. Preencha email e senha antes do primeiro up."
} else {
    Write-Output "Arquivo do administrador existente preservado em $adminPath."
}

$admin = [System.IO.File]::ReadAllText($adminPath)
$adminEmail = [regex]::Match($admin, '(?m)^ADMIN_EMAIL=([^\r\n]+)\r?$')
$adminSenha = [regex]::Match($admin, '(?m)^ADMIN_SENHA_INICIAL=([^\r\n]*)\r?$')
if (-not $adminEmail.Success -or -not $adminSenha.Success -or $adminSenha.Groups[1].Value.Length -lt 12) {
    Write-Warning "Preencha ADMIN_EMAIL e ADMIN_SENHA_INICIAL (minimo de 12 caracteres) em $adminPath antes de iniciar o Compose."
}

if ($novoEnv -or $conteudoExistente -match '(?m)^BALAIO_INTERNAL_TOKEN=[^\r\n]+\r?$') {
    & (Join-Path $PSScriptRoot 'prepare-internal-token.ps1') -EnvFile $EnvFile
} else {
    Write-Warning 'BALAIO_INTERNAL_TOKEN ausente ou vazio no .env existente. Execute prepare-internal-token.ps1 separadamente para preencher esse valor.'
}

Write-Output 'Confirme as senhas dos bancos e do administrador; revise SMTP, origem do frontend e portas antes de iniciar o Compose.'
