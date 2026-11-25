# Stub do profile-service para o benchmark de e-mail: responde o contato de qualquer conta.
param([int]$Porta = 8092)
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Porta/")
$listener.Start()
Write-Output "stub-profile ouvindo em http://localhost:$Porta/"
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $bytes = [Text.Encoding]::UTF8.GetBytes('{"dados":{"nome":"Bench","email":"bench@exemplo.com"}}')
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.KeepAlive = $false
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}
