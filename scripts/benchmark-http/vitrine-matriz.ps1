# Carga concorrente na vitrine: 1, 10 e 50 usuários virtuais, aquecimento de 10 s descartado, 5 repetições de 30 s.
$ErrorActionPreference = 'Stop'
$pasta = 'C:\dev\Artesanato\Repo\platform\scripts\benchmark-http'
$saida = 'C:\dev\Artesanato\Repo\platform\docs\benchmark\http'
$csv = Join-Path $saida 'resultados-vitrine.csv'
Remove-Item (Join-Path $saida '*.json') -ErrorAction SilentlyContinue
'vus,repeticao,duracao_s,requisicoes,vazao_por_s,p50_ms,p95_ms,p99_ms,falhas_taxa' | Set-Content -Encoding UTF8 $csv
foreach ($vus in 1, 10, 50) {
    # aquecimento (descartado): o arquivo vai para rep0 e é ignorado na análise
    docker run --rm -v "${pasta}:/scripts" -v "${saida}:/out" -e "VUS=$vus" -e "DURACAO=10s" -e "REP=aquecimento" grafana/k6:latest run --quiet /scripts/vitrine.js | Out-Null
    foreach ($rep in 1..5) {
        docker run --rm -v "${pasta}:/scripts" -v "${saida}:/out" -e "VUS=$vus" -e "DURACAO=30s" -e "REP=$rep" grafana/k6:latest run --quiet /scripts/vitrine.js | Out-Null
        $r = Get-Content (Join-Path $saida "vitrine-vus$vus-rep$rep.json") | ConvertFrom-Json
        $ci = [Globalization.CultureInfo]::InvariantCulture
        $linha = '{0},{1},30,{2},{3},{4},{5},{6},{7}' -f $vus, $rep, $r.requisicoes,
            $r.vazao_por_s.ToString('F2', $ci), $r.p50_ms.ToString('F2', $ci), $r.p95_ms.ToString('F2', $ci),
            $r.p99_ms.ToString('F2', $ci), $r.falhas_taxa.ToString('F4', $ci)
        Add-Content -Encoding UTF8 $csv $linha
        Write-Output "vus=$vus rep=$rep vazao=$([math]::Round($r.vazao_por_s,1))/s p95=$([math]::Round($r.p95_ms,1))ms falhas=$($r.falhas_taxa)"
    }
}
Write-Output 'VITRINE CONCLUIDA'
