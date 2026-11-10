# Roteiro manual de integracao do Gateway com o commerce; cria dados de teste.
param(
    [Parameter(Mandatory = $true)][string]$GatewayBase,
    [Parameter(Mandatory = $true)][string]$CommerceBase
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7 -or ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 2)) {
    throw 'test-gateway-commerce-integration.ps1 requer PowerShell 7.2 ou superior. Execute o script em um terminal pwsh. Nenhuma chamada de teste foi enviada.'
}
$root = Split-Path $PSScriptRoot -Parent

function Chamar($base, $method, $path, $body, $headers = @{}) {
    $requestOptions = @{ Uri = "$base$path"; Method = $method; Headers = $headers; SkipHttpErrorCheck = $true }
    if ($null -ne $body) {
        $requestOptions.ContentType = 'application/json'
        $requestOptions.Body = ConvertTo-Json -InputObject $body -Depth 12 -Compress
    }
    $response = Invoke-WebRequest @requestOptions
    $data = $response.Content | ConvertFrom-Json -AsHashtable
    return @{ Status = [int]$response.StatusCode; Data = $data; Headers = $response.Headers }
}

function Exigir($ok, $description) {
    if (-not $ok) { throw "Falhou: $description" }
}

function Jwt($response) {
    $cookie = @($response.Headers['Set-Cookie']) -join ';'
    if ($cookie -notmatch 'balaio_sessao=([^;]+)') { throw 'Sessão não emitida.' }
    return $Matches[1]
}

function LerConfig($path, $name) {
    $line = Get-Content -LiteralPath $path | Where-Object { $_ -match "^$name=" } | Select-Object -Last 1
    if (-not $line) { throw "Configuração ausente: $name" }
    return ($line -split '=', 2)[1].Trim()
}

$token = LerConfig "$root/.env" 'BALAIO_INTERNAL_TOKEN'
Exigir ($token.Length -ge 32) 'token interno configurado'
$unique = [Guid]::NewGuid().ToString('N').Substring(0, 10)
$password = 'QaPI190#' + [Guid]::NewGuid().ToString('N').Substring(0, 12)

$artisan = Chamar $GatewayBase 'POST' '/api/v1/auth/cadastro' @{
    nome = 'Ateliê QA PI190'; email = "artesao-$unique@example.test"; senha = $password; perfil = 'artesao'
}
Exigir ($artisan.Status -eq 201) 'cadastro do artesão pelo Gateway'
$artisanJwt = Jwt $artisan
$buyer = Chamar $GatewayBase 'POST' '/api/v1/auth/cadastro' @{
    nome = 'Comprador QA PI190'; email = "comprador-$unique@example.test"; senha = $password; perfil = 'comprador'
}
Exigir ($buyer.Status -eq 201) 'cadastro do comprador pelo Gateway'
$buyerJwt = Jwt $buyer

function CriarPeca($name) {
    $created = Chamar $GatewayBase 'POST' '/api/v1/pecas' @{
        nome = $name; tecnica = 'Cerâmica & Barro'; territorio = 'Caruaru'; categoria = 'Casa & Mesa'
        tipo = 'Jarras & Vasos'; historia = @('Peça de integração PI190'); preco = 100
        disponibilidade = 'unica'; situacao = 'publicada'; fotos = @()
    } @{ Authorization = "Bearer $artisanJwt" }
    Exigir ($created.Status -eq 201) 'publicação de peça única pelo Gateway'
    return $created.Data.dados.slug
}

$slug = CriarPeca "Vaso QA PI190 $unique"
$checkout = @{
    itens = @(@{ slug = $slug; quantidade = 1 }); freteId = 'padrao'; meio = 'pix'
    endereco = @{ cep = '52021030'; endereco = 'Rua de teste, 100'; cidade = 'Recife'; estado = 'PE' }
}
$buyerHeader = @{ Authorization = "Bearer $buyerJwt"; 'Idempotency-Key' = "qa-pi190-$unique" }
$first = Chamar $GatewayBase 'POST' '/api/v1/checkout' $checkout $buyerHeader
Exigir ($first.Status -eq 202 -and $first.Data.dados.estado -eq 'aguardando_pagamento') 'checkout e reserva'
$orderId = $first.Data.dados.id
Exigir ([decimal]$first.Data.dados.total -eq [decimal]138.90) 'preço e frete calculados no servidor'
$anotherBuyer = Chamar $GatewayBase 'POST' '/api/v1/auth/cadastro' @{
    nome = 'Outro comprador QA PI190'; email = "outro-$unique@example.test"; senha = $password; perfil = 'comprador'
}
Exigir ($anotherBuyer.Status -eq 201) 'cadastro do segundo comprador'
$competing = Chamar $GatewayBase 'POST' '/api/v1/checkout' $checkout @{
    Authorization = "Bearer $(Jwt $anotherBuyer)"; 'Idempotency-Key' = "concorrente-$unique"
}
Exigir ($competing.Status -eq 409) 'segunda compra da peça única recusada'
$repeat = Chamar $GatewayBase 'POST' '/api/v1/checkout' $checkout $buyerHeader
Exigir ($repeat.Data.dados.id -eq $orderId) 'replay idempotente do checkout'

$withoutToken = Chamar $CommerceBase 'POST' "/internal/v1/pedidos/$orderId/pagamento" @{
    eventoId = "qa-pagamento-$unique"; resultado = 'aprovado'
}
Exigir ($withoutToken.Status -eq 403) 'pagamento interno exige token'
$paid = Chamar $CommerceBase 'POST' "/internal/v1/pedidos/$orderId/pagamento" @{
    eventoId = "qa-pagamento-$unique"; resultado = 'aprovado'
} @{ 'X-Balaio-Service-Token' = $token }
Exigir ($paid.Data.dados.estado -eq 'confirmado') 'confirmação simulada consome reserva'
$sellerPending = Chamar $GatewayBase 'GET' '/api/v1/artesao/pedidos-pendentes' $null @{
    Authorization = "Bearer $artisanJwt"
}
Exigir ($sellerPending.Status -eq 200 -and @($sellerPending.Data.dados.id) -contains $orderId) 'pedido aparece no painel do ateliê'
$sellerSales = Chamar $GatewayBase 'GET' '/api/v1/artesao/vendas' $null @{
    Authorization = "Bearer $artisanJwt"
}
Exigir ($sellerSales.Status -eq 200 -and @($sellerSales.Data.dados.id) -contains $orderId) 'venda aparece para o ateliê'
$buyerSellerRoute = Chamar $GatewayBase 'GET' '/api/v1/artesao/pedidos-pendentes' $null @{
    Authorization = "Bearer $buyerJwt"
}
Exigir ($buyerSellerRoute.Status -eq 403) 'comprador não consulta pedidos do artesão'
$sellerBuyerRoute = Chamar $GatewayBase 'GET' '/api/v1/pedidos' $null @{
    Authorization = "Bearer $artisanJwt"
}
Exigir ($sellerBuyerRoute.Status -eq 403) 'artesão não consulta lista de compradores'
$anonymousSellerRoute = Chamar $GatewayBase 'GET' '/api/v1/artesao/vendas' $null
Exigir ($anonymousSellerRoute.Status -eq 401) 'vendas exigem autenticação'
$production = Chamar $GatewayBase 'PATCH' "/api/v1/pedidos/$orderId/estado" @{ estado = 'producao' } @{
    Authorization = "Bearer $artisanJwt"
}
Exigir ($production.Data.dados.estado -eq 'producao') 'produção restrita ao ateliê'
$sellerPending = Chamar $GatewayBase 'GET' '/api/v1/artesao/pedidos-pendentes' $null @{
    Authorization = "Bearer $artisanJwt"
}
Exigir (@($sellerPending.Data.dados.id) -notcontains $orderId) 'pedido aceito saiu da fila pendente'
$cancel = Chamar $GatewayBase 'PATCH' "/api/v1/pedidos/$orderId/cancelar" @{} @{
    Authorization = "Bearer $buyerJwt"
}
Exigir ($cancel.Status -eq 409 -and $cancel.Data.erro.codigo -eq 'MEDIACAO_NECESSARIA') 'mediação após produção'

$mediation = Chamar $GatewayBase 'POST' '/api/v1/admin/mediacoes' @{
    pedido = $orderId; assunto = 'Cancelar pedido'; relato = 'Solicito cancelamento durante produção.'
} @{ Authorization = "Bearer $buyerJwt" }
Exigir ($mediation.Status -eq 201) 'abertura de mediação pelo comprador'
$mediationId = $mediation.Data.dados.id
$adminEmail = LerConfig "$root/secrets/admin.env" 'ADMIN_EMAIL'
$adminPassword = LerConfig "$root/secrets/admin.env" 'ADMIN_SENHA_INICIAL'
$admin = Chamar $GatewayBase 'POST' '/api/v1/auth/login' @{
    email = $adminEmail; senha = $adminPassword
}
Exigir ($admin.Status -eq 200) 'login do administrador'
$adminJwt = Jwt $admin
$opened = Chamar $GatewayBase 'PATCH' "/api/v1/admin/mediacoes/$mediationId" @{
    estado = 'emAnalise'
} @{ Authorization = "Bearer $adminJwt" }
Exigir ($opened.Data.dados.estado -eq 'emAnalise') 'mediação em análise'
$decision = Chamar $GatewayBase 'POST' "/api/v1/admin/mediacoes/$mediationId/decisao" @{
    decisao = 'cancelar_reembolsar'
} @{ Authorization = "Bearer $adminJwt" }
Exigir ($decision.Data.dados.estado -eq 'decidida') 'decisão entregue ao commerce'
$ended = Chamar $GatewayBase 'GET' "/api/v1/pedidos/$orderId" $null @{
    Authorization = "Bearer $buyerJwt"
}
Exigir ($ended.Data.dados.estado -eq 'reembolsado') 'pedido encerrado e reserva liberada'
$listed = Chamar $GatewayBase 'GET' '/api/v1/pecas?tamanho=100' $null
Exigir (@($listed.Data.dados.slug) -contains $slug) 'peça voltou ao catálogo'

$slugCancel = CriarPeca "Vaso cancelamento QA $unique"
$checkout.itens = @(@{ slug = $slugCancel; quantidade = 1 })
$buyerHeader['Idempotency-Key'] = "qa-cancelamento-$unique"
$toCancel = Chamar $GatewayBase 'POST' '/api/v1/checkout' $checkout $buyerHeader
Exigir ($toCancel.Data.dados.estado -eq 'aguardando_pagamento') 'reserva antes do cancelamento'
$cancelled = Chamar $GatewayBase 'PATCH' "/api/v1/pedidos/$($toCancel.Data.dados.id)/cancelar" @{} @{
    Authorization = "Bearer $buyerJwt"
}
Exigir ($cancelled.Data.dados.estado -eq 'cancelado') 'cancelamento liberou reserva'
$cancelReplay = Chamar $GatewayBase 'PATCH' "/api/v1/pedidos/$($toCancel.Data.dados.id)/cancelar" @{} @{
    Authorization = "Bearer $buyerJwt"
}
Exigir ($cancelReplay.Data.dados.estado -eq 'cancelado') 'replay do cancelamento'
$listed = Chamar $GatewayBase 'GET' '/api/v1/pecas?tamanho=100' $null
Exigir (@($listed.Data.dados.slug) -contains $slugCancel) 'peça cancelada voltou ao catálogo'

$slugRefuse = CriarPeca "Vaso recusa QA $unique"
$checkout.itens = @(@{ slug = $slugRefuse; quantidade = 1 })
$buyerHeader['Idempotency-Key'] = "qa-recusa-$unique"
$toRefuse = Chamar $GatewayBase 'POST' '/api/v1/checkout' $checkout $buyerHeader
$refuseId = $toRefuse.Data.dados.id
$paidRefuse = Chamar $CommerceBase 'POST' "/internal/v1/pedidos/$refuseId/pagamento" @{
    eventoId = "qa-pagamento-recusa-$unique"; resultado = 'aprovado'
} @{ 'X-Balaio-Service-Token' = $token }
Exigir ($paidRefuse.Data.dados.estado -eq 'confirmado') 'pedido para recusa confirmado'
$refused = Chamar $GatewayBase 'PATCH' "/api/v1/pedidos/$refuseId/recusar" @{
    motivo = 'Não consigo produzir esta peça.'
} @{ Authorization = "Bearer $artisanJwt" }
Exigir ($refused.Data.dados.estado -eq 'recusado') 'recusa do ateliê liberou a peça'
$sellerPending = Chamar $GatewayBase 'GET' '/api/v1/artesao/pedidos-pendentes' $null @{
    Authorization = "Bearer $artisanJwt"
}
Exigir (@($sellerPending.Data.dados.id) -notcontains $refuseId) 'pedido recusado saiu da fila'

Write-Output 'PI-190 Gateway: checkout, disputa, replay, consultas do artesão, recusa, pagamento interno, produção, mediação, cancelamento e liberação passaram.'
