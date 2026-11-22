param(
    [string] $BaseUrl = 'http://localhost:8080',
    [string] $Origin = 'http://localhost:4321',
    [string] $MaxSizeFixture,
    [switch] $VerifyPages,
    [switch] $RestartServices,
    [switch] $VerifyStorageFailure
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$id = [Guid]::NewGuid().ToString('N')
$sessions = @([Microsoft.PowerShell.Commands.WebRequestSession]::new(),
    [Microsoft.PowerShell.Commands.WebRequestSession]::new())
$accounts = [Collections.Generic.List[string]]::new()
$slug = $null
function Api($Method, $Path, $Body, $Session, [int] $Expected = 200) {
    $options = @{ Uri = $BaseUrl.TrimEnd('/') + $Path; Method = $Method;
        SkipHttpErrorCheck = $true; TimeoutSec = 45; Headers = @{ Origin = $Origin } }
    if ($null -ne $Body) { $options.Body = $Body | ConvertTo-Json -Depth 12 -Compress; $options.ContentType = 'application/json' }
    if ($null -ne $Session) { $options.WebSession = $Session }
    $response = Invoke-WebRequest @options
    if ([int]$response.StatusCode -ne $Expected) {
        $code = try { ($response.Content | ConvertFrom-Json).erro.codigo } catch { 'SEM_ENVELOPE' }
        throw "Falha $Method $Path : HTTP $($response.StatusCode), codigo $code (esperado $Expected)."
    }
    if ($response.Headers.'Content-Type' -match 'json') { return ($response.Content | ConvertFrom-Json) }
    return $response
}
function Pass([string] $Message) { Write-Output "PASS: $Message" }
function Verify-Object([string] $Url, [int] $Status) {
    $name = $Url.Substring('/api/v1/arquivos/pecas/'.Length)
    $actual = $null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $actual = & docker compose exec -T seaweedfs /bin/sh /opt/balaio/storage/catalog-object-status.sh "catalog/$slug/$name"
        if ($LASTEXITCODE -eq 0 -and [int]$actual -eq $Status) { return }
        if ($Status -ne 404) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($LASTEXITCODE -ne 0 -or [int]$actual -ne $Status) { throw "Objeto S3: esperado $Status, recebido $actual." }
}
$png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg=='
if ($MaxSizeFixture) {
    $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($MaxSizeFixture))
    if ($bytes.Length -ne 5 * 1024 * 1024) { throw 'Fixture deve ter exatamente 5 MiB.' }
    $png = [Convert]::ToBase64String($bytes)
}
$expectedBytes = [Convert]::FromBase64String($png)
function Verify-Photo([string] $Url) {
    $r = Api GET $Url $null $null
    if ($r.Headers.'Content-Type' -notmatch 'image/png' -or
        [Convert]::ToBase64String($r.RawContentStream.ToArray()) -cne $png) { throw 'Binario da imagem divergente.' }
}
Push-Location $repo
try {
    foreach ($index in 0..1) {
        $password = 'Pi175!' + [Guid]::NewGuid().ToString('N') + 'Aa1'
        $created = Api POST '/api/v1/auth/cadastro' @{
            nome = "Diagnostico fotos $index"; email = "pi175-$id-$index@example.invalid";
            senha = $password; perfil = 'artesao'
        } $sessions[$index] 201
        $accounts.Add(([Guid]$created.dados.id).ToString())
    }
    Pass 'cadastro e sessao real de dois artesaos'
    $refs = (Api GET '/api/v1/referencias' $null $null).dados
    $fotos = @(0..4 | ForEach-Object { @{ id = "foto-$_"; nome = "foto-$_.png"; url = "data:image/png;base64,$png" } })
    $created = Api POST '/api/v1/pecas' @{
        nome = "Diagnostico PI175 $id"; tecnica = $refs.tecnicas[0]; territorio = $refs.territorios[0];
        categoria = $refs.categorias[0]; tipo = $refs.tipos[0]; historia = @('Foto de diagnostico');
        preco = 10; disponibilidade = 'disponivel'; situacao = 'publicada'; fotos = $fotos
    } $sessions[0] 201
    $slug = $created.dados.slug
    $photos = @($created.dados.fotos)
    if ($photos.Count -ne 5) { throw 'Galeria nao retornou cinco fotos.' }
    foreach ($photo in $photos) { Verify-Photo $photo.url }
    foreach ($photo in $photos) { Verify-Object $photo.url 200 }
    Pass 'cinco uploads reais e leitura publica de todos os binarios'
    $null = Api PATCH "/api/v1/pecas/$slug" @{ fotos = @() } $null 401
    $null = Api PATCH "/api/v1/pecas/$slug" @{ fotos = @() } $sessions[1] 404
    Pass 'alteracao anonima ou por outro artesao recusada'
    $ordered = @($photos[4..0] | ForEach-Object { @{ id = $_.id; nome = $_.nome; url = $_.url } })
    $null = Api PATCH "/api/v1/pecas/$slug" @{ fotos = $ordered } $sessions[0]
    $reloaded = (Api GET "/api/v1/pecas/$slug" $null $null).dados
    if (($reloaded.fotos.id -join ',') -cne ($ordered.id -join ',') -or $reloaded.imagem -cne $ordered[0].url) {
        throw 'Ordem/capa nao persistida.'
    }
    Pass 'reordenacao e capa persistidas apos recarga'
    if ($VerifyPages) {
        foreach ($pagePath in @("/pieces/$slug", "/dashboard/pieces/$slug")) {
            $page = Api GET $pagePath $null $sessions[0]
            $html = [Text.Encoding]::UTF8.GetString($page.RawContentStream.ToArray())
            if (-not $html.Contains($created.dados.nome) -or -not $html.Contains($ordered[0].url)) {
                throw "Pagina $pagePath nao renderizou a peca e sua galeria reais."
            }
        }
        Pass 'detalhe publico e pagina de edicao renderizam peca e fotos reais'
    }
    $null = Api PATCH "/api/v1/pecas/$slug" @{ fotos = @($ordered + @{ id = 'sexta'; nome = 'sexta.png'; url = "data:image/png;base64,$png" }) } $sessions[0] 400
    $null = Api PATCH "/api/v1/pecas/$slug" @{ fotos = @(@{id='gif';nome='foto.gif';url='data:image/gif;base64,R0lGODlh'}) } $sessions[0] 400
    Pass 'quantidade e formato invalidos recusados'
    if ($MaxSizeFixture) {
        $oversize = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($MaxSizeFixture)) + [byte]0
        $null = Api PATCH "/api/v1/pecas/$slug" @{ fotos = @(@{id='grande';nome='grande.png';url=('data:image/png;base64,' + [Convert]::ToBase64String($oversize))}) } $sessions[0] 400
        Pass '5 MiB por arquivo aceitos; 5 MiB mais um byte recusado'
    }
    if ($VerifyStorageFailure) {
        & docker compose stop seaweedfs
        if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel pausar storage.' }
        try {
            $failure = Api GET $ordered[0].url $null $null 503
            if ($failure.erro.codigo -ne 'STORAGE_INDISPONIVEL') { throw 'Erro de storage sem envelope padrao.' }
            $null = Api PATCH "/api/v1/pecas/$slug" @{ fotos = @(@{id='falha';nome='falha.png';url="data:image/png;base64,$png"}) } $sessions[0] 503
            $unchanged = (Api GET "/api/v1/pecas/$slug" $null $null).dados
            if (($unchanged.fotos.id -join ',') -cne ($ordered.id -join ',')) { throw 'Falha de upload modificou referencias.' }
            Pass 'storage parado retorna 503 e upload falho preserva a galeria'
        } finally {
            & docker compose --profile storage up -d --no-deps --wait --wait-timeout 90 seaweedfs
            if ($LASTEXITCODE -ne 0) { throw 'Storage nao recuperou saude.' }
        }
    }
    if ($RestartServices) {
        & docker compose restart catalog-service seaweedfs
        if ($LASTEXITCODE -ne 0) { throw 'Restart falhou.' }
        & docker compose up -d --no-deps --wait --wait-timeout 90 catalog-service seaweedfs
        if ($LASTEXITCODE -ne 0) { throw 'Servicos nao recuperaram saude apos restart.' }
        $ready = $false
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            try { Verify-Photo $ordered[0].url; $ready = $true; break } catch { Start-Sleep -Seconds 1 }
        }
        if (-not $ready) { throw 'Leitura apos restart nao ficou disponivel.' }
        $reloaded = (Api GET "/api/v1/pecas/$slug" $null $null).dados
        if (($reloaded.fotos.id -join ',') -cne ($ordered.id -join ',')) { throw 'Ordem perdida apos restart.' }
        Pass 'binario, galeria e ordem preservados apos restart de catalogo e storage'
    }
    $replacement = @{id='nova';nome='nova.png';url="data:image/png;base64,$png"}
    $updated = Api PATCH "/api/v1/pecas/$slug" @{ fotos = @($ordered[0], $replacement) } $sessions[0]
    Verify-Photo $updated.dados.fotos[1].url
    $null = Api GET $ordered[1].url $null $null 404
    foreach ($photo in $ordered[1..4]) { Verify-Object $photo.url 404 }
    Pass 'substituicao com foto nova e URLs removidas retornando 404'
    $null = Api PATCH "/api/v1/pecas/$slug" @{ fotos = @() } $sessions[0]
    foreach ($photo in $updated.dados.fotos) { $null = Api GET $photo.url $null $null 404 }
    foreach ($photo in $updated.dados.fotos) { Verify-Object $photo.url 404 }
    Pass 'remocao completa sem referencias quebradas na peca'
} finally {
    if ($slug) {
        try {
            $null = Api PATCH "/api/v1/pecas/$slug" @{ fotos = @() } $sessions[0]
            $null = Api DELETE "/api/v1/pecas/$slug" $null $sessions[0] 204
            # Delete only this generated diagnostic piece after API cleanup of its objects.
            if ($slug -notmatch '^diagnostico-pi175-[a-f0-9]{32}$') { throw 'Slug de limpeza invalido.' }
            & docker compose exec -T catalog-db psql -U postgres -d balaio_catalog -v ON_ERROR_STOP=1 -c "DELETE FROM pecas WHERE slug = '$slug' AND proprietario_id = '$($accounts[0])'" | Out-Null
        } catch { Write-Warning 'Limpeza da peca de diagnostico pendente; conferir antes de repetir.' }
    }
    foreach ($account in $accounts) {
        & docker compose exec -T profile-db psql -U balaio_profile_app -d balaio_profile -v ON_ERROR_STOP=1 -c "DELETE FROM contas WHERE id = '$account' AND email LIKE 'pi175-$id-%@example.invalid'" | Out-Null
    }
    Pop-Location
}
