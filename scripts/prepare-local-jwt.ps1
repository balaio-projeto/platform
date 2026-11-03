param(
    [string] $Directory = (Join-Path $PSScriptRoot '..\secrets')
)

$ErrorActionPreference = 'Stop'
$privatePath = Join-Path $Directory 'jwt-private.pem'
$publicPath = Join-Path $Directory 'jwt-public.pem'
$adminPath = Join-Path $Directory 'admin.env'
$hasPrivate = Test-Path -LiteralPath $privatePath -PathType Leaf
$hasPublic = Test-Path -LiteralPath $publicPath -PathType Leaf

if ($hasPrivate -xor $hasPublic) {
    throw 'Par JWT incompleto: forneça as duas chaves ou remova a chave isolada antes de preparar o ambiente.'
}

if (-not $hasPrivate) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $rsa = [System.Security.Cryptography.RSA]::Create(3072)
    try {
        [System.IO.File]::WriteAllText($privatePath, $rsa.ExportPkcs8PrivateKeyPem())
        [System.IO.File]::WriteAllText($publicPath, $rsa.ExportSubjectPublicKeyInfoPem())
    } finally {
        $rsa.Dispose()
    }
}

$privateRsa = [System.Security.Cryptography.RSA]::Create()
$publicRsa = [System.Security.Cryptography.RSA]::Create()
try {
    $privateRsa.ImportFromPem([System.IO.File]::ReadAllText($privatePath))
    $publicRsa.ImportFromPem([System.IO.File]::ReadAllText($publicPath))
    if ($privateRsa.KeySize -lt 3072 -or $publicRsa.KeySize -lt 3072) {
        throw 'O par JWT precisa ter ao menos 3072 bits.'
    }
    $amostra = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $assinatura = $privateRsa.SignData($amostra,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if (-not $publicRsa.VerifyData($amostra, $assinatura,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
        throw 'As chaves JWT não formam um par correspondente.'
    }
    Write-Output "Par JWT local válido em $Directory"
} finally {
    $privateRsa.Dispose()
    $publicRsa.Dispose()
}

if (-not (Test-Path -LiteralPath $adminPath -PathType Leaf)) {
    $senha = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
    [System.IO.File]::WriteAllText($adminPath,
        "ADMIN_EMAIL=admin@localhost.test`nADMIN_SENHA_INICIAL=$senha`n")
}
$admin = [System.IO.File]::ReadAllText($adminPath)
if ($admin -notmatch '(?m)^ADMIN_EMAIL=.+$' -or $admin -notmatch '(?m)^ADMIN_SENHA_INICIAL=.{12,}$') {
    throw 'Configuração local do administrador inicial inválida em admin.env.'
}
Write-Output "Bootstrap do administrador local preparado em $adminPath"
