# Platform Balaio

Repositório para reunir configurações e recursos compartilhados do desenvolvimento local dos serviços do Balaio. A aplicação continua dividida entre repositórios independentes: `api-gateway`, `catalog-service`, `profile-service`, `commerce-service`, `community-service` e `events-service`.

## Escopo inicial

- Centralizar orientações e arquivos de apoio ao ambiente local.
- Manter a collection Bruno usada para validar as rotas pelo gateway.
- Servir de ponto de integração para a configuração Docker Compose, que será adicionada na história atribuída a outro membro da equipe.

## Collection Bruno

A collection em `bruno/balaio-api` começa com a listagem de peças pelo gateway:

```http
GET http://localhost:8080/api/v1/pecas
```

O ambiente `Local` define `baseUrl` como `http://localhost:8080`. Abra a pasta `bruno/balaio-api` no Bruno e selecione esse ambiente. A collection usa OpenCollection YAML e requer uma versão do Bruno com suporte a esse formato.

## Configuração local

Use `.env.example` como referência para configurar as variáveis de ambiente nos perfis de execução locais dos serviços. Copie os valores para o mecanismo de configuração da sua IDE ou terminal e substitua o placeholder da senha por uma credencial local. O arquivo `.env` é ignorado pelo Git.

Ao executar os serviços diretamente pela IDE, Spring Boot não carrega automaticamente um arquivo `.env`; configure as variáveis no perfil de execução. A forma de carregá-las pelo Docker Compose será documentada quando a configuração compartilhada for integrada.

## Fluxo atual de catálogo

1. O frontend chama `GET /api/v1/pecas` no `api-gateway`.
2. O gateway encaminha a requisição ao `catalog-service`.
3. O `catalog-service` consulta seu PostgreSQL e devolve a resposta do catálogo.

Cada serviço permanece responsável pelos dados do próprio domínio. O gateway é a entrada HTTP do frontend e não acessa o banco de dados dos serviços.
