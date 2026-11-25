# TC33 (TS18): ambiente integrado com bancos isolados, dados e mídia persistentes.
# Somente leitura por padrão. Com -ReiniciarContainers, reinicia os serviços do Compose e confere
# se os dados e a mídia continuam disponíveis depois do reinício.
# O "ambiente limpo" (cópia isolada, migrações do zero, dataset) é preparado à parte;
# este script valida o resultado desse ambiente.
[CmdletBinding()]
param(
    [string] $GatewayBase = 'http://localhost:8080',
    [switch] $ReiniciarContainers,
    [int] $TempoDeEsperaSegundos = 180
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.2') { throw 'Execute com PowerShell 7.2+: pwsh -File scripts/test-ambiente-limpo.ps1' }

$root = Split-Path $PSScriptRoot -Parent
$resultados = [System.Collections.Generic.List[object]]::new()

function Registrar([string] $nome, [bool] $ok, [string] $detalhe = '') {
    $resultados.Add([pscustomobject]@{ Teste = $nome; Resultado = $(if ($ok) { 'OK' } else { 'FALHOU' }); Detalhe = $detalhe })
}

# Os bancos de commerce, community e events ficam no perfil "extended".
$perfis = @('--profile', 'extended')

function Compose([string[]] $argumentos) {
    Push-Location $root
    try {
        $saida = & docker compose @perfis @argumentos 2>$null
        if ($LASTEXITCODE -ne 0) { throw "docker compose $($argumentos -join ' ') falhou." }
        return $saida
    } finally { Pop-Location }
}

# 1. Configuração: cinco bancos próprios, cada um com volume e URL de conexão exclusivos.
$config = (Compose @('config', '--format', 'json')) -join "`n" | ConvertFrom-Json
$bancos = @('catalog-db', 'profile-db', 'commerce-db', 'community-db', 'events-db')
$servicos = $config.services.PSObject.Properties
$existentes = $bancos | Where-Object { $config.services.PSObject.Properties.Name -contains $_ }
Registrar 'Cinco bancos declarados no Compose' ($existentes.Count -eq 5) "encontrados: $($existentes.Count)"

$volumesDosBancos = foreach ($banco in $existentes) {
    @($config.services.$banco.volumes | ForEach-Object { $_.source }) | Where-Object { $_ }
}
Registrar 'Volumes de dados dos bancos não se repetem' (($volumesDosBancos | Select-Object -Unique).Count -eq $volumesDosBancos.Count) `
    "volumes: $($volumesDosBancos -join ', ')"

$urlsDeConexao = foreach ($servico in $servicos) {
    $env = $servico.Value.environment
    if (-not $env) { continue }
    foreach ($nome in @('SPRING_DATASOURCE_URL', 'CATALOG_DB_URL')) {
        if ($env.PSObject.Properties.Name -contains $nome) { $env.$nome }
    }
}
Registrar 'Cada serviço aponta para uma URL de banco própria' (($urlsDeConexao | Select-Object -Unique).Count -eq $urlsDeConexao.Count -and $urlsDeConexao.Count -ge 5) `
    "URLs distintas: $(@($urlsDeConexao | Select-Object -Unique).Count) de $($urlsDeConexao.Count)"

# 2. Execução: serviços e bancos saudáveis.
$estado = (Compose @('ps', '--format', 'json')) -join "`n"
$linhas = $estado -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
$naoSaudaveis = @($linhas | Where-Object { $_.Health -and $_.Health -ne 'healthy' } | ForEach-Object { $_.Service })
$naoRodando = @($linhas | Where-Object { $_.State -ne 'running' } | ForEach-Object { $_.Service })
Registrar 'Todos os serviços em execução' ($naoRodando.Count -eq 0) "fora do ar: $($naoRodando -join ', ')"
Registrar 'Todos os serviços com healthcheck saudável' ($naoSaudaveis.Count -eq 0) "não saudáveis: $($naoSaudaveis -join ', ')"

function Consultar([string] $caminho) {
    try { return Invoke-RestMethod -Uri "$GatewayBase$caminho" -TimeoutSec 20 }
    catch { return $null }
}

$pecasAntes = Consultar '/api/v1/pecas?tamanho=100'
$quantidadeAntes = if ($pecasAntes) { @($pecasAntes.dados).Count } else { -1 }
# Mídia persistida pelo storage tem URL em /api/v1/arquivos/. Imagens /fotos/*.svg são do seed legado da Fake API.
$imagemAntes = @($pecasAntes.dados | Where-Object { $_.imagem -like '/api/v1/arquivos/*' } | Select-Object -First 1 | ForEach-Object { $_.imagem })
$imagensLegadas = @($pecasAntes.dados | Where-Object { $_.imagem -and $_.imagem -notlike '/api/v1/arquivos/*' }).Count
Registrar 'Catálogo público responde pelo gateway' ($null -ne $pecasAntes) "peças publicadas: $quantidadeAntes"
$urlMidia = $null
if ($imagemAntes) { $urlMidia = if ($imagemAntes -match '^https?://') { $imagemAntes } else { "$GatewayBase$imagemAntes" } }
if ($urlMidia) {
    $midia = Invoke-WebRequest -Uri $urlMidia -Method Get -SkipHttpErrorCheck -TimeoutSec 20
    Registrar 'Mídia de peça publicada é acessível pela URL' ($midia.StatusCode -eq 200) "status: $($midia.StatusCode)"
} else {
    Registrar 'Mídia de peça publicada é acessível pela URL' $false `
        "nenhuma peça com mídia do storage; $imagensLegadas peça(s) usam imagens legadas do seed (/fotos/*.svg)"
}

# 3. Reinício: dados e mídia precisam sobreviver.
if ($ReiniciarContainers) {
    Compose @('restart') | Out-Null
    $limite = (Get-Date).AddSeconds($TempoDeEsperaSegundos)
    do {
        Start-Sleep -Seconds 5
        $pendentes = @((Compose @('ps', '--format', 'json')) -join "`n" -split "`n" | Where-Object { $_.Trim() } |
            ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.Health -and $_.Health -ne 'healthy' })
    } while ($pendentes.Count -gt 0 -and (Get-Date) -lt $limite)
    Registrar 'Serviços voltam saudáveis após o reinício' ($pendentes.Count -eq 0) "pendentes: $($pendentes.Service -join ', ')"

    $pecasDepois = Consultar '/api/v1/pecas?tamanho=100'
    $quantidadeDepois = if ($pecasDepois) { @($pecasDepois.dados).Count } else { -1 }
    Registrar 'Catálogo mantém as mesmas peças após o reinício' ($quantidadeDepois -eq $quantidadeAntes) `
        "antes: $quantidadeAntes, depois: $quantidadeDepois"
    if ($urlMidia) {
        $midiaDepois = Invoke-WebRequest -Uri $urlMidia -Method Get -SkipHttpErrorCheck -TimeoutSec 20
        Registrar 'Mídia continua acessível após o reinício' ($midiaDepois.StatusCode -eq 200) "status: $($midiaDepois.StatusCode)"
    }
}

$resultados | Format-Table -AutoSize
$falhas = @($resultados | Where-Object { $_.Resultado -ne 'OK' })
if ($falhas.Count -gt 0) { throw "TC33: $($falhas.Count) verificação(ões) falharam." }
Write-Host 'TC33: todas as verificações passaram.'
