# Platform Balaio

Repositório de apoio ao desenvolvimento local do Balaio. Os serviços continuam em repositórios independentes; este Compose constrói as imagens locais e inicia a fatia integrada atual.

## Serviços iniciados

| Serviço | Porta no computador | Função |
| --- | ---: | --- |
| Frontend | 4321 | Next.js; as áreas ainda não integradas continuam usando a Fake API incluída na imagem do frontend |
| API Gateway | 8080 | Entrada HTTP do frontend e encaminhamento para o catálogo |
| Catalog service | 8081 | Consulta e persistência das peças |
| PostgreSQL | 5433 | Banco do catálogo; a porta interna do container continua 5432 |

O banco do Compose é separado do PostgreSQL instalado no computador. O mapeamento padrão usa a porta 5433 para evitar conflito com a instância local que normalmente ocupa a 5432. O catálogo tem seu próprio usuário e banco. O volume `catalog-db-data` mantém os dados entre reinicializações.

## Organização local

Clone os repositórios lado a lado, mantendo esta estrutura:

```text
Repo/
├── Balaio/Frontend/
├── api-gateway/
├── catalog-service/
└── platform/
```

O Compose usa os repositórios do gateway, catálogo e frontend como contextos de build. Cada aplicação é construída em uma imagem separada.

## Primeiro uso

No PowerShell, dentro da pasta `platform`:

```powershell
Copy-Item .env.example .env
```

Edite `.env` e substitua `CATALOG_DB_PASSWORD` e `POSTGRES_ADMIN_PASSWORD` por senhas locais. Se a porta 5433 já estiver ocupada, altere `CATALOG_DB_HOST_PORT`.

Suba a aplicação:

```powershell
docker compose up --build
```

Abra `http://localhost:4321/search`. O frontend chama o gateway pela rede interna do Compose. Para testar a mesma rota pelo Bruno, use o ambiente `Local` e `http://localhost:8080/api/v1/pecas`. O ambiente `Catalog local` acessa diretamente `http://localhost:8081/api/v1/pecas`.

A primeira inicialização cria o banco `balaio_catalog` e o usuário da aplicação. Em seguida, o Flyway do catálogo aplica as migrações e os dados iniciais.

## Comandos úteis

```powershell
docker compose ps
docker compose logs -f frontend api-gateway catalog-service
docker compose down
```

`docker compose down` mantém os dados do banco no volume. Para apagar o banco descartável do Compose e recriá-lo do zero:

```powershell
docker compose down -v
```

Esse último comando remove os dados persistidos pelo Compose.

## Rede e variáveis

Dentro da rede do Compose, o gateway acessa `http://catalog-service:8081`, o catálogo acessa `catalog-db:5432` e o frontend acessa `http://api-gateway:8080/api/v1`. Esses endereços usam os nomes dos serviços; dentro de um container, `localhost` aponta para o próprio container.

O Compose sobrescreve a URL do banco e do catálogo para usar esses nomes internos. Para executar os serviços diretamente pela IDE, configure as variáveis do `.env` no perfil de execução. O Spring Boot não carrega automaticamente o arquivo `.env`.

## Bruno

A collection está em `bruno/balaio-api` e contém a listagem de peças. Use `Local` para testar pelo gateway e `Catalog local` para testar o serviço sem gateway.

## Escopo

Este ambiente local inicia frontend, gateway, catálogo e banco do catálogo. As demais rotas do frontend permanecem na Fake API até a integração dos respectivos serviços. Novos serviços podem ser adicionados ao Compose à medida que suas APIs e configurações locais estiverem prontas.