# Ambiente do benchmark (item 3.2)

Registrado em 24/11/2026. Hardware e software usados nas medições de e-mail e HTTP.

| Item | Valor |
|---|---|
| CPU | AMD Ryzen 7 5700X, 8 núcleos físicos, 16 threads |
| RAM | 32 GB |
| SO | Windows 11 Pro |
| Docker | Docker Desktop, engine 29.9.3 |
| JDK (build e execução do commerce-service) | OpenJDK 25.0.5 (ms-25.0.5.0.2) |
| PostgreSQL | 18.6, imagem `postgres:18-alpine`, `max_connections=100` |
| Pool Hikari | padrão do Spring Boot (10 conexões), sem configuração no projeto |
| SMTP local | Mailpit v1.34.0, retenção ilimitada (`MP_MAX_MESSAGES=0`) |
| Latência de e-mail | Toxiproxy (`ghcr.io/shopify/toxiproxy:latest`), toxic `latency` no downstream, aplicado por resposta SMTP |
| Profile (stub) | PowerShell `HttpListener`, porta 8092, resposta fixa |

## Configurações fixadas nas medições de e-mail

- `mail.smtp.localhost=localhost` e `mail.from=bench@localhost`: evitam a consulta DNS reversa do JavaMail a cada envio, que neste host custava vários segundos por envio (ver `platform/docs/benchmark/` e o harness `medir-drenagem.ps1`).
- `balaio.mail.max-lotes-por-ciclo=100000`: drena a fila inteira em cada ciclo do worker.
- Propriedades passadas por argumento de linha de comando, não por variável de ambiente.

## Limitações

- Tudo roda na mesma máquina (cliente, serviços, banco e SMTP), então há disputa de CPU e de rede loopback.
- O SMTP é um Mailpit com latência artificial, não um provedor real.
- O profile é um stub; o custo real da chamada ao profile-service não é medido.
