# ADR-003: Manter as consultas do catálogo otimizadas no PostgreSQL, sem introduzir CQRS ou cache.

- **Status:** Proposta
- **Data:** 2026-11-23
- **Autor:** MATHEUS ANDRADE SILVA (mas7@cesar.school)
- **Turma:** Embarque (segundas)
- **Projeto:** Origem · marketplace da economia criativa e do artesanato de Pernambuco

## Contexto

O catalog-service é responsável pelo gerenciamento e pela consulta das peças artesanais do marketplace Origem. Atualmente, o serviço utiliza PostgreSQL para executar buscas textuais, filtros, ordenações e paginação diretamente no banco de dados. A aplicação segue uma arquitetura hexagonal leve, separando controllers, casos de uso, domínio e adaptadores de persistência.

Foram realizadas medições de desempenho da vitrine, incluindo testes com uma base ampliada para aproximadamente 21 mil peças. Os resultados ficaram abaixo da meta de 300 ms no percentil 95. O projeto possui prazo de um semestre, equipe reduzida e orçamento limitado para infraestrutura, tornando importante evitar componentes adicionais sem necessidade comprovada.

## Preocupações

Tempo de resposta, desempenho das consultas, escalabilidade, experiência do comprador, custo de infraestrutura, complexidade de manutenção e prazo de desenvolvimento.

## Decisão

Manter a arquitetura de Portas e Adaptadores já utilizada pelo catalog-service, concentrando as consultas de busca, filtros, ordenação e paginação no PostgreSQL, por meio dos adaptadores de persistência. Não introduzir CQRS, Redis ou bancos de leitura separados enquanto as medições permanecerem dentro da meta de desempenho estabelecida.

## Justificativa

A decisão considera que o catálogo já possui mecanismos de busca textual, filtros combinados, paginação e ordenação executados diretamente no PostgreSQL. As medições registradas no projeto demonstram tempos de resposta inferiores à meta de 300 ms no p95, inclusive com avaliações de consultas utilizando uma base ampliada de aproximadamente 21 mil peças. Dessa forma, a introdução de CQRS ou cache adicionaria complexidade de implementação, manutenção e consistência sem apresentar benefício comprovado. A manutenção da arquitetura atual atende às necessidades de desempenho e respeita as limitações de prazo, equipe e infraestrutura do projeto.

## Consequências

Positivas:
- Aproveitamento da arquitetura e das implementações existentes.
- Menor complexidade de desenvolvimento e manutenção.
- Ausência de custos adicionais com infraestrutura de cache.
- Preservação da consistência dos dados utilizando o PostgreSQL.
- Facilidade de monitorar e otimizar as consultas existentes.
Negativas:
- As operações de leitura continuam dependendo do desempenho do PostgreSQL.
- Consultas mais complexas poderão exigir novas otimizações e índices.
- O crescimento do catálogo poderá aumentar o tempo de resposta.
- Caso o volume de consultas aumente significativamente, poderá ser necessário reavaliar a arquitetura de leitura futuramente.

## Alternativas consideradas

CQRS: considerado para separar os modelos de leitura e escrita, mas descartado porque as consultas atuais já apresentam desempenho adequado. Sua adoção aumentaria a complexidade sem uma necessidade comprovada.
Redis: considerado para armazenar resultados de consultas frequentes e reduzir acessos ao banco, mas descartado porque as medições atuais estão abaixo da meta de desempenho. Também exigiria mecanismos de invalidação e controle de consistência do cache.
Bancos de leitura separados: descartados devido ao aumento da complexidade de infraestrutura, sincronização e manutenção, sem justificativa para o volume atual do catálogo.

## Rastreabilidade

**Atributo de qualidade:** Confiabilidade · Tolerância a falhas

**Cenário que originou a decisão:**

> Quando dois ou mais compradores autenticados tentarem reservar simultaneamente a mesma peça artesanal (fonte do estímulo), enviando solicitações concorrentes de reserva (estímulo), o catalog-service, especificamente o módulo de gerenciamento de disponibilidade e reservas e sua persistência no PostgreSQL (artefato), deverá manter seu funcionamento durante a operação normal do marketplace, mesmo com múltiplas requisições simultâneas (ambiente). O sistema deverá garantir que somente um comprador consiga reservar a peça, enquanto as demais solicitações receberão uma resposta de conflito, sem gerar reservas duplicadas ou inconsistências no estado do produto (resposta). Para 100 solicitações simultâneas referentes à mesma peça, exatamente uma deverá resultar em reserva válida, as outras 99 deverão retornar HTTP 409, deverá existir exatamente uma reserva ativa ou consumida no banco de dados e nenhuma solicitação deverá resultar em erro HTTP 500 (medida da resposta).

**Padrão arquitetural adotado:** Portas e Adaptadores

**Táticas empacotadas:** Encapsular a dependência externa; Usar intermediário (a porta); Inverter e injetar dependência; Isolar dependência externa para teste; Adiar vinculação para tempo de configuração

- Microsserviço: catalog-service.
- Módulo: peca/application e peca/persistence.
- Adaptador: persistência PostgreSQL.
- Funcionalidades: busca textual, filtros, ordenação e paginação.
- Banco de dados: PostgreSQL.
- Atributo: Eficiência de desempenho.
- Subcaracterística: Comportamento temporal.
- Requisitos relacionados: buscar e navegar na vitrine.
- Referência de implementação: PI-178, PI-179 e PI-180.

## Verificação

- **Teste do cenário:** Será realizado um teste de desempenho da API GET /api/v1/pecas, utilizando o Gateway e uma base de dados com aproximadamente 21 mil peças cadastradas, incluindo cenários de listagem, busca textual, aplicação de filtros, ordenação e paginação.
O teste deverá executar pelo menos 300 requisições por cenário, após 20 requisições de aquecimento, registrando os percentis p50, p95 e p99.
Critérios de aprovação:
- O p95 das requisições realizadas pelo Gateway deverá ser inferior a 300 ms.
- As consultas deverão retornar os resultados corretos, respeitando os filtros, ordenações e paginação.
- Nenhuma requisição deverá apresentar erro HTTP 500.
- Caso o p95 ultrapasse a meta, deverão ser avaliados primeiro os planos de execução, os índices e as consultas SQL antes de considerar a introdução de cache ou CQRS.
A decisão será considerada validada quando os critérios forem atendidos e as medições forem reproduzíveis.

---

_Gerado pelo estudo dirigido de Arquitetura de Software · ADS020 · 2026.2._
