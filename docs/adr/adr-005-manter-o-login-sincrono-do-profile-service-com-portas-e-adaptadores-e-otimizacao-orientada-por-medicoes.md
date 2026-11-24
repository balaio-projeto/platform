# ADR-005: Manter o login síncrono do profile-service com Portas e Adaptadores e otimização orientada por medições

- **Status:** Proposta
- **Data:** 2026-11-23
- **Autor:** FERNANDO MARINHO DE FREITAS FILHO (fmff@cesar.school)
- **Turma:** Embarque (segundas)
- **Projeto:** Origem · marketplace da economia criativa e do artesanato de Pernambuco

## Contexto

O profile-service do Origem é responsável pelas contas e pelos perfis dos usuários, incluindo a autenticação de compradores e artesãos. Atualmente, o login recebe as credenciais pelo api-gateway, consulta a conta no PostgreSQL, verifica a senha e emite a sessão. Sua implementação já separa o recebimento HTTP, o caso de uso e os mecanismos de acesso a dados e verificação de senha por meio de portas e adaptadores.

O projeto possui prazo de um semestre, equipe pequena, tecnologias previamente acordadas e infraestrutura limitada. Nesse contexto, precisamos oferecer uma autenticação com tempo de resposta previsível, aproveitando os componentes existentes. Foi proposta a meta de responder a pelo menos 95% das tentativas de login em até um segundo, sob carga de 20 usuários virtuais simultâneos. Essa meta ainda não foi comprovada por teste de carga.

## Preocupações

Tempo de resposta, autenticação segura, consumo de CPU, acesso ao PostgreSQL, concorrência, identificação de gargalos, complexidade de implementação, prazo e custo de infraestrutura.

## Decisão

Manter o processamento síncrono do login no profile-service, utilizando a organização existente de Portas e Adaptadores. Medir o fluxo completo pelo gateway e aplicar otimizações nos componentes identificados como gargalos, preservando as verificações de segurança e validando novamente o cenário após os ajustes.

## Justificativa

O login precisa fornecer o resultado da autenticação na mesma interação para que o usuário possa continuar sua navegação. Manter esse fluxo síncrono evita introduzir filas e mecanismos de consulta posterior do resultado, aproveitando a implementação existente e os recursos disponíveis.

Portas e Adaptadores permite preservar o contrato do caso de uso enquanto a implementação de persistência ou outros componentes são ajustados. Essa separação apoia a investigação e a realização de mudanças localizadas, mas não garante, isoladamente, o tempo de resposta desejado. Por isso, a decisão inclui medir a consulta à conta, a verificação da senha e a emissão da sessão, além do tempo total observado pelo cliente. As otimizações deverão ser justificadas pelos resultados, sem reduzir a proteção das senhas para cumprir a meta.

## Consequências

A decisão aproveita a estrutura atual do profile-service e evita acrescentar componentes de infraestrutura. A separação de responsabilidades permite investigar o tempo gasto em cada etapa e realizar ajustes preservando as regras da autenticação e o contrato HTTP.

Como custo, a equipe deverá manter interfaces e adaptadores, compreender o fluxo entre esses componentes e preparar testes de carga reproduzíveis. A verificação segura de senhas continuará consumindo recursos de processamento, e o serviço permanecerá dependente da disponibilidade e do desempenho do PostgreSQL. Se a meta não for atendida após os ajustes, será necessário reavaliar a capacidade do ambiente e as decisões de implementação com base nas medições.

## Alternativas consideradas

Foi considerado o processamento do login por uma arquitetura Orientada a Eventos. Essa alternativa foi descartada para o fluxo principal porque o usuário precisa receber imediatamente o resultado da validação das credenciais e, quando autorizado, a sessão. O processamento assíncrono acrescentaria coordenação e acompanhamento de resultados sem benefício demonstrado para a carga definida.

Também foi considerada uma reorganização em Camadas. Embora possa atender ao fluxo e à meta de desempenho, a mudança não apresenta benefício temporal comprovado e exigiria retrabalho na estrutura já existente. Optamos por preservar Portas e Adaptadores e concentrar o esforço na medição e nos ajustes necessários.

## Rastreabilidade

**Atributo de qualidade:** Eficiência de desempenho · Comportamento temporal

**Cenário que originou a decisão:**

> Ambiente de homologação com recursos documentados, gateway, profile-service e PostgreSQL disponíveis, sob carga de 20 usuários virtuais simultâneos durante cinco minutos. Cada usuário envia uma requisição por vez e aguarda um segundo após a resposta antes da próxima tentativa., compradores e artesãos que desejam acessar suas contas no origem. Envio simultâneo de solicitações de login com e-mail e senha pela rota POST /api/v1/auth/login, através do api-gateway. Fluxo de autenticação do profile-service, incluindo consulta da conta no PostgreSQL, verificação da senha e emissão da sessão.. O sistema valida as credenciais, autentica as contas válidas e emite a sessão, retornando HTTP 200. Tentativas com senha incorreta são rejeitadas com HTTP 401, sem emissão de sessão e preservando as verificações de segurança., Pelo menos 95% das requisições devem responder em até um segundo, medido pelo cliente através do gateway. O teste utilizará contas previamente cadastradas, com 80% de tentativas válidas e 20% com senha incorreta. Todas devem apresentar o resultado esperado, sem erros HTTP 500 ou timeouts, configurados em cinco segundos..

**Padrão arquitetural adotado:** Portas e Adaptadores

**Táticas empacotadas:** Encapsular a dependência externa; Usar intermediário (a porta); Inverter e injetar dependência

Microsserviço: profile-service. Funcionalidade: autenticação de compradores e artesãos. Endpoint: POST /api/v1/auth/login, acessado pelo api-gateway. Componentes identificados: AutenticacaoController, EfetuarLoginUseCase, EfetuarLoginService, ContasPort, VerificarSenhaPort, EmissorJwtAdapter e CookieSessaoAdapter. Persistência: PostgreSQL próprio do profile-service. O teste de carga proposto deverá ser versionado no repositório junto ao roteiro de execução e aos resultados obtidos.

## Verificação

- **Teste do cenário:** Será realizado um teste de carga em homologação, utilizando o gateway, o profile-service, o PostgreSQL e os mecanismos reais de verificação de senha e emissão de sessão. Os recursos do ambiente, as versões e a quantidade de contas utilizadas serão registrados para permitir a reprodução.

Após um período de aquecimento, serão executados 20 usuários virtuais simultâneos durante cinco minutos. Cada usuário enviará uma requisição por vez e aguardará um segundo após a resposta antes da próxima tentativa. A carga utilizará contas previamente cadastradas, com 80% de tentativas válidas e 20% com senha incorreta.

O teste será aprovado se pelo menos 95% das requisições responderem em até um segundo, medido pelo cliente através do gateway; todas as tentativas válidas retornarem HTTP 200 com emissão de sessão; e todas as tentativas com senha incorreta retornarem HTTP 401 sem emissão de sessão. Nenhuma requisição poderá apresentar erro HTTP 500 ou atingir o timeout de cinco segundos.

Serão registrados o total de requisições, os percentis p50, p95 e p99, os códigos de resposta e o consumo de recursos. Caso a meta não seja atendida, os tempos das etapas internas orientarão os ajustes, e o mesmo teste será repetido para comparar os resultados.

---

_Gerado pelo estudo dirigido de Arquitetura de Software · ADS020 · 2026.2._
