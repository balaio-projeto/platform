param(
    [string] $EnvFile = (Join-Path $PSScriptRoot '..\.env'),
    [string] $SecretsDirectory = (Join-Path $PSScriptRoot '..\secrets')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.2') {
    throw 'prepare-local-storage.ps1 requer PowerShell 7.2 ou superior. Nenhum arquivo foi alterado.'
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$EnvFile = [IO.Path]::GetFullPath($EnvFile)
$SecretsDirectory = [IO.Path]::GetFullPath($SecretsDirectory)
$tlsDirectory = Join-Path $SecretsDirectory 'seaweedfs'
$caDirectory = Join-Path $SecretsDirectory 'seaweedfs-ca'
$paths = @((Join-Path $tlsDirectory 'ca.crt'), (Join-Path $tlsDirectory 'tls.crt'),
    (Join-Path $tlsDirectory 'tls.key'), (Join-Path $caDirectory 'ca.key'))

# Require Git ignore protection before creating or editing sensitive material.
foreach ($path in @($EnvFile) + $paths) {
    & git -C $repo check-ignore --quiet -- $path 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Caminho sensivel nao protegido pelo Git ignore. Nenhum segredo foi gerado.' }
    & git -C $repo ls-files --error-unmatch -- $path 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) { throw 'Arquivo sensivel rastreado pelo Git. Provisionamento recusado.' }
}
if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) { throw 'Prepare o .env pelo setup-local.ps1 antes do storage.' }
$original = [IO.File]::ReadAllText($EnvFile)
$values = @{}
foreach ($name in @('S3_ACCESS_KEY_ID', 'S3_SECRET_ACCESS_KEY', 'S3_HOST_PORT')) {
    $found = [regex]::Matches($original, "(?m)^$name=([^\r\n]*)\r?$")
    if ($found.Count -gt 1) { throw 'Variavel S3 duplicada. Revise o .env sem divulgar os valores.' }
    $value = if ($found.Count) { $found[0].Groups[1].Value } else { '' }
    # Literal single-quoted dotenv values preserve $, #, spaces, quotes and backslashes.
    if ($value.StartsWith("'")) {
        if (-not $value.EndsWith("'") -or $value.Length -lt 2) { throw 'Valor S3 com aspas incompletas.' }
        $value = $value.Substring(1, $value.Length - 2).Replace("\'", "'")
    } elseif ($value -match '[\s#\x22\x24]') {
        throw 'Use valor dotenv literal entre aspas simples para caracteres especiais em S3.'
    }
    $values[$name] = $value
}
$hasAccess = $values.S3_ACCESS_KEY_ID.Length -gt 0
$hasSecret = $values.S3_SECRET_ACCESS_KEY.Length -gt 0
if ($hasAccess -xor $hasSecret) { throw 'Par S3 incompleto; nenhum valor existente foi substituido.' }
if ($hasAccess -and ($values.S3_ACCESS_KEY_ID -notmatch '^[A-Za-z0-9_-]{20,128}$' -or
        $values.S3_SECRET_ACCESS_KEY -notmatch '^[\x20-\x7e]{40,256}$')) {
    throw 'Credenciais S3 invalidas; nenhum valor existente foi substituido.'
}
if ($values.S3_HOST_PORT -and ($values.S3_HOST_PORT -notmatch '^\d{1,5}$' -or
        [int]$values.S3_HOST_PORT -lt 1 -or [int]$values.S3_HOST_PORT -gt 65535)) {
    throw 'S3_HOST_PORT invalida.'
}
$present = @($paths | Where-Object { Test-Path -LiteralPath $_ })
if ($present.Count -ne 0 -and $present.Count -ne $paths.Count) {
    throw 'Conjunto de certificados incompleto. Restaure o conjunto original; nao foi sobrescrito.'
}

function Write-NewPrivateFile([string] $Path, [string] $Content) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
}
function Protect-NewDirectory([string] $Path) {
    if (Test-Path -LiteralPath $Path) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if ($IsWindows) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
                [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl',
                'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } else {
        throw 'Provisionamento de permissoes suportado no Windows. Configure ownership UID 1000 antes de usar em Linux.'
    }
}

function Assert-Certificates {
    $ca = $leaf = $caRsa = $leafRsa = $chain = $null
    try {
        $caDer = [Convert]::FromBase64String(([IO.File]::ReadAllText($paths[0]) -replace '-----[^-]+-----|\s', ''))
        $leafDer = [Convert]::FromBase64String(([IO.File]::ReadAllText($paths[1]) -replace '-----[^-]+-----|\s', ''))
        $ca = [Security.Cryptography.X509Certificates.X509Certificate2]::new($caDer)
        $leaf = [Security.Cryptography.X509Certificates.X509Certificate2]::new($leafDer)
        foreach ($cert in @($ca, $leaf)) {
            if ($cert.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
                $cert.NotAfter.ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(7)) { throw 'Certificado fora da validade ou proximo do vencimento.' }
        }
        if ($leaf.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne 'seaweedfs-internal') {
            throw 'Identidade TLS incorreta.'
        }
        $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $san.AddDnsName('seaweedfs'); $san.AddDnsName('localhost'); $san.AddIpAddress([Net.IPAddress]::Loopback)
        $actualSan = @($leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })
        if ($actualSan.Count -ne 1 -or [Convert]::ToBase64String($actualSan[0].RawData) -ne
                [Convert]::ToBase64String($san.Build().RawData)) { throw 'SAN TLS incompativel com o storage.' }
        $eku = @($leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' })
        if ($eku.Count -ne 1 -or @($eku[0].EnhancedKeyUsages.Value) -notcontains '1.3.6.1.5.5.7.3.1' -or
                @($eku[0].EnhancedKeyUsages.Value) -notcontains '1.3.6.1.5.5.7.3.2') { throw 'EKU TLS incompativel.' }
        $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
        $chain.ChainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        [void]$chain.ChainPolicy.CustomTrustStore.Add($ca)
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        if (-not $chain.Build($leaf)) { throw 'Cadeia TLS invalida.' }
        $caRsa = [Security.Cryptography.RSA]::Create()
        $leafRsa = [Security.Cryptography.RSA]::Create()
        $caRsa.ImportFromPem([IO.File]::ReadAllText($paths[3]))
        $leafRsa.ImportFromPem([IO.File]::ReadAllText($paths[2]))
        foreach ($pair in @(@($ca, $caRsa), @($leaf, $leafRsa))) {
            $public = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($pair[0])
            try {
                if ($pair[1].KeySize -lt 3072 -or
                    [Convert]::ToBase64String($public.ExportSubjectPublicKeyInfo()) -ne
                    [Convert]::ToBase64String($pair[1].ExportSubjectPublicKeyInfo())) { throw 'Chave TLS nao corresponde ao certificado.' }
            } finally { $public.Dispose() }
        }
    } catch {
        throw 'Validacao dos certificados falhou. Preserve os arquivos e restaure um conjunto valido; nenhum segredo foi exibido.'
    } finally {
        foreach ($item in @($ca, $leaf, $caRsa, $leafRsa, $chain)) { if ($null -ne $item) { $item.Dispose() } }
    }
}

if ($present.Count -eq 0) {
    Protect-NewDirectory $tlsDirectory
    Protect-NewDirectory $caDirectory
    $caKey = [Security.Cryptography.RSA]::Create(3072)
    $leafKey = [Security.Cryptography.RSA]::Create(3072)
    $ca = $leaf = $null
    try {
        $hash = [Security.Cryptography.HashAlgorithmName]::SHA256
        $padding = [Security.Cryptography.RSASignaturePadding]::Pkcs1
        $caRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Balaio Local Storage CA', $caKey, $hash, $padding)
        $caRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
        $caRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign, $true))
        $now = [DateTimeOffset]::UtcNow
        $ca = $caRequest.CreateSelfSigned($now.AddMinutes(-5), $now.AddYears(10))
        $leafRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=seaweedfs-internal', $leafKey, $hash, $padding)
        $leafRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
        $leafRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment, $true))
        $eku = [Security.Cryptography.OidCollection]::new()
        [void]$eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        [void]$eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.2'))
        $leafRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku, $false))
        $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $san.AddDnsName('seaweedfs'); $san.AddDnsName('localhost'); $san.AddIpAddress([Net.IPAddress]::Loopback)
        $leafRequest.CertificateExtensions.Add($san.Build())
        $serial = [Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
        $serial[0] = $serial[0] -band 0x7f
        $leaf = $leafRequest.Create($ca, $now.AddMinutes(-5), $now.AddYears(2), $serial)
        # ExportCertificatePem is not available in every PS 7.2 runtime.
        $caPem = "-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($ca.RawData, 'InsertLineBreaks') + "`n-----END CERTIFICATE-----`n"
        $leafPem = "-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($leaf.RawData, 'InsertLineBreaks') + "`n-----END CERTIFICATE-----`n"
        Write-NewPrivateFile $paths[0] $caPem
        Write-NewPrivateFile $paths[1] $leafPem
        Write-NewPrivateFile $paths[2] $leafKey.ExportPkcs8PrivateKeyPem()
        Write-NewPrivateFile $paths[3] $caKey.ExportPkcs8PrivateKeyPem()
    } finally {
        foreach ($item in @($ca, $leaf, $caKey, $leafKey)) { if ($null -ne $item) { $item.Dispose() } }
    }
}
Assert-Certificates

$updated = $original
if (-not $hasAccess) {
    $values.S3_ACCESS_KEY_ID = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $values.S3_SECRET_ACCESS_KEY = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    foreach ($name in @('S3_ACCESS_KEY_ID', 'S3_SECRET_ACCESS_KEY')) {
        $line = $name + '=' + $values[$name]
        if ($updated -match "(?m)^$name=") {
            $updated = [regex]::Replace($updated, "(?m)^$name=[^\r\n]*", $line)
        } else { $updated = $updated.TrimEnd("`r", "`n") + "`r`n$line`r`n" }
    }
}
if (-not $values.S3_HOST_PORT) {
    if ($updated -match '(?m)^S3_HOST_PORT=') {
        $updated = [regex]::Replace($updated, '(?m)^S3_HOST_PORT=[^\r\n]*', 'S3_HOST_PORT=8333')
    } else { $updated = $updated.TrimEnd("`r", "`n") + "`r`nS3_HOST_PORT=8333`r`n" }
}
if ($updated -cne $original) {
    # Refuse concurrent edits rather than silently overwriting them.
    if ([IO.File]::ReadAllText($EnvFile) -cne $original) { throw 'O .env mudou durante o provisionamento; nenhuma alteracao foi gravada nele.' }
    [IO.File]::WriteAllText($EnvFile, $updated, [Text.UTF8Encoding]::new($false))
}
Write-Output 'Storage local preparado: credenciais preservadas/geradas, certificados validados, sem segredos na saida.'
