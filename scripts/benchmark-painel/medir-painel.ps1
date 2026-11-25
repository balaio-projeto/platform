<#
Mede o painel do artesão (GET /api/v1/artesao/painel/resumo) nos modos sequencial e paralelo (item 3.2).
Pré-requisitos: bench-pg, bench-catalog-pg, bench-toxi (proxy 'catalogo' 8091 -> catalog 8081), catalog-service
rodando na 8081 com as peças do artesão de teste, e o stub do profile (8092).
A latência é injetada no catálogo (downstream do proxy), uma resposta por chamada do painel.
Medição com curl.exe (tempo total do cliente), 5 chamadas de aquecimento e 30 cronometradas por repetição.
#>
param(
    [int[]]$LatenciasMs = @(0, 100, 300),
    [int]$Repeticoes = 5,
    [string]$Saida = 'C:\dev\Artesanato\Repo\platform\docs\benchmark\painel\resultados-painel.csv'
)
$ErrorActionPreference = 'Stop'
$jar = 'C:\dev\Artesanato\Repo\commerce-service\target\commerce-service-0.0.1-SNAPSHOT.jar'
$pem = "$env:TEMP\bench-jwt-pub.pem"
$token = Get-Content "$env:TEMP\bench-token.txt"
$pasta = Split-Path $Saida
if (-not (Test-Path $pasta)) { New-Item -ItemType Directory -Path $pasta | Out-Null }
if (-not (Test-Path $Saida)) { 'data_hora,modo,latencia_ms,repeticao,media_ms,p50_ms,p95_ms' | Set-Content -Encoding UTF8 $Saida }
$ci = [Globalization.CultureInfo]::InvariantCulture
$url = 'http://localhost:8083/api/v1/artesao/painel/resumo'

function Definir-Latencia([int]$ms) {
    try { Invoke-RestMethod -UserAgent 'curl/8.5.0' -Method Delete -Uri 'http://localhost:8474/proxies/catalogo/toxics/latencia' | Out-Null } catch {}
    if ($ms -gt 0) {
        $corpo = @{ name = 'latencia'; type = 'latency'; stream = 'downstream'; toxicity = 1
                    attributes = @{ latency = $ms; jitter = 0 } } | ConvertTo-Json -Depth 4
        Invoke-RestMethod -UserAgent 'curl/8.5.0' -Method Post -Uri 'http://localhost:8474/proxies/catalogo/toxics' -ContentType 'application/json' -Body $corpo | Out-Null
    }
}

function Chamar-Painel {
    [double]::Parse((& curl.exe -s -o NUL -H "Authorization: Bearer $token" -w '%{time_total}' $url), $ci) * 1000
}

function Iniciar-Commerce([bool]$paralelo) {
    $env:SPRING_DATASOURCE_URL = 'jdbc:postgresql://localhost:55432/balaio_commerce'
    $env:SPRING_DATASOURCE_USERNAME = 'bench'; $env:SPRING_DATASOURCE_PASSWORD = 'bench'
    $env:COMMERCE_SMTP_HOST = 'localhost'; $env:COMMERCE_SMTP_PORT = '1026'
    $env:PROFILE_SERVICE_URL = 'http://localhost:8092'
    $env:CATALOG_SERVICE_URL = 'http://localhost:8091'
    $env:BALAIO_INTERNAL_TOKEN = 'bench-token-com-mais-de-trinta-e-dois-caracteres'
    $env:COMMERCE_SERVICE_PORT = '8083'
    $env:JWT_PUBLIC_KEY_LOCATION = 'file:' + $pem.Replace([string][char]92, [string][char]47)
    $env:JWT_ISSUER = 'bench-issuer'; $env:JWT_AUDIENCE = 'bench-audience'
    $args_ = @('-jar', $jar, "--balaio.painel.paralelo=$($paralelo.ToString().ToLower())", '--balaio.mail.worker-enabled=false')
    $log = "$env:TEMP\bench-painel-$([guid]::NewGuid().ToString('N')).log"
    $p = Start-Process -FilePath "$env:JAVA_HOME\bin\java.exe" -ArgumentList $args_ -WorkingDirectory 'C:\dev\Artesanato\Repo\commerce-service' `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        try { Invoke-WebRequest -UseBasicParsing http://localhost:8083/actuator/health -TimeoutSec 2 | Out-Null; return $p } catch { }
    }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    throw "commerce-service não subiu (ver $log)"
}

foreach ($modo in @(@{ Nome = 'sequencial'; Paralelo = $false }, @{ Nome = 'paralelo'; Paralelo = $true })) {
    $app = Iniciar-Commerce $modo.Paralelo
    try {
        for ($rep = 1; $rep -le $Repeticoes; $rep++) {
            foreach ($lat in $LatenciasMs) {
                Definir-Latencia $lat
                1..5 | ForEach-Object { Chamar-Painel | Out-Null }
                $tempos = @(1..30 | ForEach-Object { Chamar-Painel })
                $ordenados = $tempos | Sort-Object
                $media = ($tempos | Measure-Object -Average).Average
                $p50 = $ordenados[[int][math]::Floor(0.50 * ($ordenados.Count - 1))]
                $p95 = $ordenados[[int][math]::Floor(0.95 * ($ordenados.Count - 1))]
                $linha = '{0},{1},{2},{3},{4},{5},{6}' -f (Get-Date -Format 's'), $modo.Nome, $lat, $rep,
                    $media.ToString('F2', $ci), $p50.ToString('F2', $ci), $p95.ToString('F2', $ci)
                Add-Content -Encoding UTF8 -Path $Saida -Value $linha
                Write-Output ("{0} lat={1}ms rep={2}: media={3:N1} ms p95={4:N1} ms" -f $modo.Nome, $lat, $rep, $media, $p95)
            }
        }
    }
    finally {
        if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
        Start-Sleep -Seconds 2
    }
}
Definir-Latencia 0
Write-Output 'PAINEL CONCLUIDO'
