# Matriz reduzida do benchmark de e-mail (item 3.2): 6 cenários centrais, 5 repetições cada.
$ErrorActionPreference = 'Continue'
$h = Join-Path $PSScriptRoot 'medir-drenagem.ps1'
$csv = 'C:\dev\Artesanato\Repo\platform\docs\benchmark\resultados-email.csv'
Remove-Item $csv -ErrorAction SilentlyContinue
$cenarios = @(
    @{ V = 1000; L = 0;   P = $false; C = 8 },
    @{ V = 1000; L = 0;   P = $true;  C = 8 },
    @{ V = 1000; L = 20;  P = $false; C = 8 },
    @{ V = 1000; L = 20;  P = $true;  C = 8 },
    @{ V = 200;  L = 100; P = $false; C = 8 },
    @{ V = 200;  L = 100; P = $true;  C = 8 }
)
foreach ($c in $cenarios) {
    $args_ = @{ Volume = $c.V; LatenciaMs = $c.L; Concorrencia = $c.C; Repeticoes = 5; Saida = $csv }
    if ($c.P) { $args_['Paralelo'] = $true }
    Write-Output ("cenario V={0} L={1}ms paralelo={2} C={3}" -f $c.V, $c.L, $c.P, $c.C)
    & $h @args_ 2>&1 | Where-Object { $_ -notmatch 'NOTICE' }
}
Write-Output 'MATRIZ CONCLUIDA'
