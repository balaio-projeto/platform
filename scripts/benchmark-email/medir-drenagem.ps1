<#
Mede o tempo para esvaziar a fila de e-mails do commerce-service.
Pré-requisitos (containers do benchmark): bench-pg (PostgreSQL 18, porta 55432), bench-mailpit,
bench-toxi (Toxiproxy, API 8474, proxy 1026 -> mailpit:1025) e o stub do profile (porta 8092).

Uso exemplo:
  ./medir-drenagem.ps1 -Volume 1000 -Paralelo:$false -LatenciaMs 20 -Repeticoes 5
A latência é aplicada por resposta SMTP (downstream do Toxiproxy), então um envio tem várias respostas.
#>
param(
    [int]$Volume = 100,
    [switch]$Paralelo,
    [int]$Concorrencia = 8,
    [int]$LatenciaMs = 0,
    [int]$Repeticoes = 1,
    [switch]$Aquecimento,
    [string]$Saida = "C:\dev\Artesanato\Repo\platform\docs\benchmark\resultados-email.csv"
)

$ErrorActionPreference = 'Stop'
$jar = 'C:\dev\Artesanato\Repo\commerce-service\target\commerce-service-0.0.1-SNAPSHOT.jar'
$pasta = Split-Path $Saida
if (-not (Test-Path $pasta)) { New-Item -ItemType Directory -Path $pasta | Out-Null }
if (-not (Test-Path $Saida)) {
    'data_hora,volume,paralelo,concorrencia,latencia_ms,repeticao,enviados,tempo_s,vazao_por_s,falhas,mensagens_mailpit' | Set-Content -Encoding UTF8 $Saida
}
$pem = "$env:TEMP\bench-jwt-pub.pem"
if (-not (Test-Path $pem)) { throw "Chave pública de teste ausente: $pem" }

function Invoke-Psql([string]$sql) {
    (docker exec bench-pg psql -U bench -d balaio_commerce -tA -c $sql) -join "`n"
}

function Definir-Latencia([int]$ms) {
    try { Invoke-RestMethod -UserAgent 'curl/8.5.0' -Method Delete -Uri 'http://localhost:8474/proxies/smtp/toxics/latencia' | Out-Null } catch {}
    if ($ms -gt 0) {
        $corpo = @{ name = 'latencia'; type = 'latency'; stream = 'downstream'; toxicity = 1
                    attributes = @{ latency = $ms; jitter = 0 } } | ConvertTo-Json -Depth 4
        Invoke-RestMethod -UserAgent 'curl/8.5.0' -Method Post -Uri 'http://localhost:8474/proxies/smtp/toxics' -ContentType 'application/json' -Body $corpo | Out-Null
    }
}

function Iniciar-App([bool]$paralelo) {
    $env:SPRING_DATASOURCE_URL = 'jdbc:postgresql://localhost:55432/balaio_commerce'
    $env:SPRING_DATASOURCE_USERNAME = 'bench'
    $env:SPRING_DATASOURCE_PASSWORD = 'bench'
    $env:COMMERCE_SMTP_HOST = 'localhost'
    $env:COMMERCE_SMTP_PORT = '1026'
    $env:PROFILE_SERVICE_URL = 'http://localhost:8092'
    $env:BALAIO_INTERNAL_TOKEN = 'bench-token-com-mais-de-trinta-e-dois-caracteres'
    $env:COMMERCE_SERVICE_PORT = '8083'
    $env:JWT_PUBLIC_KEY_LOCATION = 'file:' + $pem.Replace([string][char]92, [string][char]47)
    $env:JWT_ISSUER = 'bench-issuer'
    $env:JWT_AUDIENCE = 'bench-audience'
    $args_ = @('-jar', $jar,
        "--balaio.mail.paralelo=$($paralelo.ToString().ToLower())",
        "--balaio.mail.concorrencia=$Concorrencia",
        '--balaio.mail.max-lotes-por-ciclo=100000',
        '--spring.mail.properties.mail.smtp.localhost=localhost',
        '--spring.mail.properties.mail.from=bench@localhost')
    $log = "$env:TEMP\bench-app-$([guid]::NewGuid().ToString('N')).log"
    $p = Start-Process -FilePath "$env:JAVA_HOME\bin\java.exe" -ArgumentList $args_ `
        -WorkingDirectory 'C:\dev\Artesanato\Repo\commerce-service' -RedirectStandardOutput $log `
        -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        try { Invoke-WebRequest -UseBasicParsing http://localhost:8083/actuator/health -TimeoutSec 2 | Out-Null; return $p }
        catch { }
    }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    throw "commerce-service não subiu (ver $log)"
}

function Parar-App($p) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 2
}

for ($rep = 1; $rep -le $Repeticoes; $rep++) {
    Definir-Latencia $LatenciaMs
    try { Invoke-RestMethod -Method Delete -Uri 'http://localhost:8025/api/v1/messages' | Out-Null } catch {}
    $app = Iniciar-App $Paralelo.IsPresent
    try {
        if ($Aquecimento) {
            # aquecimento na mesma JVM e com a mesma concorrência: carrega as classes do envio antes da medição
            Get-Content "$PSScriptRoot\seed.sql" -Raw | docker exec -i bench-pg psql -U bench -d balaio_commerce -v "n=200" -q -f - | Out-Null
            $limiteAq = (Get-Date).AddMinutes(5)
            do {
                Start-Sleep -Seconds 2
                $pendAq = [int](Invoke-Psql "SELECT count(*) FROM pedido_emails WHERE estado = 'pendente'")
                if ((Get-Date) -gt $limiteAq) { throw "aquecimento não esvaziou em 5 min (pendentes=$pendAq)" }
            } while ($pendAq -gt 0)
            try { Invoke-RestMethod -Method Delete -Uri 'http://localhost:8025/api/v1/messages' | Out-Null } catch {}
        }
        # semeia depois de subir, antes do primeiro ciclo do worker (15 s)
        Get-Content "$PSScriptRoot\seed.sql" -Raw | docker exec -i bench-pg psql -U bench -d balaio_commerce -v "n=$Volume" -q -f - | Out-Null
        $limite = (Get-Date).AddMinutes(30)
        do {
            Start-Sleep -Seconds 2
            $pendentes = [int](Invoke-Psql "SELECT count(*) FROM pedido_emails WHERE estado = 'pendente'")
            if ((Get-Date) -gt $limite) { throw "fila não esvaziou em 30 min (pendentes=$pendentes)" }
        } while ($pendentes -gt 0)
        $linha = Invoke-Psql "SELECT count(*) FILTER (WHERE estado='enviado'), EXTRACT(EPOCH FROM (max(enviado_em)-min(enviado_em))) FROM pedido_emails"
        $partes = $linha.Split('|')
        $enviados = [int]$partes[0]
        $tempo = [double]::Parse($partes[1], [Globalization.CultureInfo]::InvariantCulture)
        $vazao = if ($tempo -gt 0) { [Math]::Round($enviados / $tempo, 2) } else { 0 }
        # marcarEnviado também incrementa tentativas; falha real = estado falhou ou pendente já tentado
        $falhas = [int](Invoke-Psql "SELECT count(*) FROM pedido_emails WHERE estado = 'falhou' OR (estado = 'pendente' AND tentativas > 0)")
        $mensagens = [int](Invoke-RestMethod -Uri 'http://localhost:8025/api/v1/messages?limit=0').total
        if ($mensagens -ne $Volume -or $falhas -ne 0 -or $enviados -ne $Volume) {
            Write-Warning "integridade: volume=$Volume enviados=$enviados falhas=$falhas mensagens=$mensagens"
        }
        $ci = [Globalization.CultureInfo]::InvariantCulture
        $registro = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10}' -f (Get-Date -Format 's'), $Volume,
            ($Paralelo.IsPresent.ToString().ToLower()), $Concorrencia, $LatenciaMs, $rep, $enviados,
            $tempo.ToString('F3', $ci), $vazao.ToString('F2', $ci), $falhas, $mensagens
        Add-Content -Encoding UTF8 -Path $Saida -Value $registro
        Write-Output "rep $rep/${Repeticoes}: enviados=$enviados tempo=$([Math]::Round($tempo,2)) s vazao=$vazao/s falhas=$falhas mensagens=$mensagens"
    }
    finally {
        Parar-App $app
    }
}
