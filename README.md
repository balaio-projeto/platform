# Platform Balaio

Ambiente de desenvolvimento local do Balaio. Cada aplicação tem seu repositório e sua imagem. O Compose monta a rede, os bancos PostgreSQL e os containers que você escolher iniciar.

## Repositórios lado a lado

```text
Repo/
├── Balaio/Frontend/
├── api-gateway/
├── catalog-service/
├── profile-service/
├── commerce-service/
├── community-service/
├── events-service/
└── platform/
```

## O que é configurado automaticamente

O `Dockerfile` de cada serviço constrói sua imagem e declara a porta interna; ele não cria banco nem publica portas no computador. O `docker-compose.yml` dá nome aos containers, conecta todos na mesma rede, publica as portas e fornece ao serviço a URL JDBC, o usuário e a senha do próprio banco. A imagem PostgreSQL cria os bancos e usuários na primeira inicialização dos respectivos volumes. O catálogo usa também seu script de inicialização para criar o banco e o usuário da aplicação.

As portas internas e os nomes usados entre containers permanecem fixos. Para mudar apenas a porta acessada pelo computador, use as variáveis `*_HOST_PORT` do `.env.example`.

## Serviços

| Aplicação | Porta HTTP | Banco e porta no computador | Inicialização padrão |
| --- | ---: | --- | --- |
| Frontend | 4321 | — | Sim |
| api-gateway | 8080 | — | Sim |
| catalog-service | 8081 | catalog-db, 5433 | Sim |
| profile-service | 8082 | profile-db, 5434 | Opcional |
| commerce-service | 8083 | commerce-db, 5435 | Opcional |
| community-service | 8084 | community-db, 5436 | Opcional |
| events-service | 8085 | events-db, 5437 | Opcional |

Cada serviço de negócio usa seu próprio banco e volume. Os bancos dos quatro serviços opcionais são novos containers; o banco e o volume existentes do catálogo permanecem os mesmos. O gateway recebe os endereços internos dos cinco serviços mesmo quando algum deles está parado. As rotas sem implementação no serviço de destino ainda retornarão erro.

## Primeiro uso

Uma instalação nova não precisa de `.env`. No PowerShell, dentro de `platform`, inicie a fatia integrada atual:

```powershell
docker compose up --build -d
```

O Compose usa `balaio` como senha compartilhada de desenvolvimento e as portas da tabela acima. Se quiser outra senha ou outras portas no computador, copie `.env.example` para `.env` e altere apenas os valores desejados:

```powershell
Copy-Item .env.example .env
```

`DB_PASSWORD` vale para os cinco bancos, inclusive para o administrador do PostgreSQL do catálogo. Cada serviço continua com banco, usuário e volume próprios. Não versione `.env`.

Se você já usa este ambiente, mantenha o `.env` atual: `POSTGRES_ADMIN_PASSWORD`, `CATALOG_DB_PASSWORD` e eventuais senhas individuais continuam aceitas e têm prioridade. Os volumes PostgreSQL já criados conservam as senhas antigas; adicionar ou mudar `DB_PASSWORD` sozinho não troca a senha gravada neles. Assim, o ambiente existente continua funcionando sem recriar bancos.

Inicie os cinco serviços de negócio, os bancos, o gateway e o frontend:

```powershell
docker compose --profile extended up --build -d
```

Inicie só um serviço adicional e seu banco:

```powershell
docker compose up --build -d profile-service
```

Troque `profile-service` por `commerce-service`, `community-service` ou `events-service` conforme o trabalho do dia. O Compose inicia o banco exigido pelo serviço escolhido. Depois da primeira criação, os containers aparecem no grupo `balaio-local` do Docker Desktop; ali você pode iniciar ou parar os containers individualmente. Para o serviço responder, inicie também o banco correspondente. O gateway pode continuar ligado quando um serviço opcional estiver desligado.

Abra `http://localhost:4321/search`. O frontend chama o gateway pela rede interna do Compose. No Bruno, use o ambiente `Local` e `http://localhost:8080/api/v1/pecas`.

## Comandos úteis

```powershell
docker compose ps
docker compose logs -f api-gateway catalog-service
docker compose down
```

`docker compose down` preserva os volumes. `docker compose down -v` apaga os bancos locais do Compose; use esse comando somente se quiser perder esses dados. As portas HTTP e dos bancos no computador são configuráveis por `*_HOST_PORT` no `.env`; dentro da rede do Compose, as portas internas continuam as mesmas.

Para executar um serviço pela IDE, use a URL JDBC com `localhost` e a porta do banco na tabela acima, além do usuário e da senha configurada para aquele banco. Para executar dentro do Compose, as URLs JDBC e o endereço de cada serviço são configurados automaticamente pelos nomes dos containers. O Spring Boot não lê `.env` sozinho fora do Compose.

## Estado da integração

O catálogo já implementa a listagem de peças. Os outros quatro serviços têm a infraestrutura para iniciar, mas ainda precisam implementar entidades, migrações e endpoints. O gateway já encaminha os caminhos atuais da Fake API para seus donos; `GET /api/v1/estado` depende de definir como compor dados de três serviços. Recomendações por IA e indicadores administrativos ficam para depois da entrega das telas atuais.

A collection Bruno está em `bruno/balaio-api`.
