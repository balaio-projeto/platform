# ADR-001: Adotar Portas e Adaptadores no microsserviço de catálogo do Origem

- **Status:** Proposta
- **Data:** 2026-11-23
- **Autor:** DIOGO FELIPE CAVALCANTE TOME (dfct@cesar.school)
- **Turma:** Embarque (segundas)
- **Projeto:** Origem · marketplace da economia criativa e do artesanato de Pernambuco

## Contexto

O Projeto Origem é um marketplace voltado à comercialização de produtos artesanais, permitindo que artesãos publiquem suas peças, compradores naveguem pela vitrine e realizem pedidos, e administradores acompanhem a operação. O projeto é desenvolvido por uma equipe pequena de estudantes, com prazo de um semestre, tecnologias e modelo de dados previamente acordados e infraestrutura limitada. Uma das necessidades da plataforma é permitir a evolução do catálogo de produtos, como a inclusão de informações sobre materiais e técnicas de produção, sem comprometer outros serviços. Por isso, a modificabilidade foi definida como atributo prioritário para orientar a organização interna do catálogo.

## Preocupações

Modificabilidade, baixo acoplamento, separação de responsabilidades, testabilidade, prazo de desenvolvimento, complexidade de manutenção, infraestrutura limitada.

## Decisão

Adotar o padrão Portas e Adaptadores (Arquitetura Hexagonal) na organização interna do microsserviço de catálogo do Origem, separando as regras de negócio dos mecanismos de persistência e comunicação externa. As interações com banco de dados e outros serviços deverão ocorrer por interfaces bem definidas, permitindo modificar funcionalidades do catálogo com menor impacto nas demais partes do sistema.

## Justificativa

A adoção de Portas e Adaptadores atende ao cenário de modificabilidade definido anteriormente, pois reduz a dependência entre as regras de negócio e os componentes técnicos do catálogo. Dessa forma, ao adicionar informações como "técnica de produção" e "material utilizado" aos produtos artesanais, a equipe poderá concentrar as alterações no serviço responsável pelo catálogo e em sua persistência, sem exigir modificações nos demais microsserviços. O padrão também facilita a criação de testes e futuras evoluções, sem exigir infraestrutura adicional, respeitando as limitações do projeto.

## Consequências

Como consequência positiva, a arquitetura permitirá uma melhor organização do código, menor acoplamento entre regras de negócio e componentes técnicos, maior facilidade para realizar testes e menor impacto de futuras alterações no catálogo. Isso beneficia a manutenção e a evolução do marketplace. Como consequência negativa, será necessário criar e manter interfaces, adaptadores e separações adicionais de responsabilidades, aumentando a quantidade de código e o esforço inicial de desenvolvimento. A equipe também precisará compreender o padrão para utilizá-lo corretamente, o que pode representar um desafio considerando o prazo de um semestre.

## Alternativas consideradas

Foi considerado o padrão Orientado a Eventos, que permite reduzir o acoplamento na comunicação entre microsserviços por meio da publicação e do consumo de eventos. Entretanto, essa alternativa foi descartada para o cenário atual porque poderia exigir mecanismos adicionais de mensageria, tratamento de falhas e controle de consistência dos dados, aumentando a complexidade operacional. Também foi considerada a arquitetura em Camadas, que apresenta implementação mais simples, mas pode favorecer dependências diretas entre regras de negócio e infraestrutura caso não exista uma separação rigorosa. Portas e Adaptadores foi escolhido por oferecer maior isolamento das regras de negócio sem exigir novos componentes de infraestrutura.

## Rastreabilidade

**Atributo de qualidade:** Manutenibilidade · Modificabilidade

**Cenário que originou a decisão:**

> Em ambiente de desenvolvimento, um desenvolvedor da equipe do Projeto Origem recebe a solicitação de adicionar os campos "técnica de produção" e "material utilizado" ao cadastro dos produtos artesanais. A alteração deve ser realizada no microsserviço responsável pelo catálogo e em seu banco de dados, sem exigir modificações nos demais microsserviços. A implementação deverá ser concluída em até um ciclo de sprint, alterando apenas o serviço de catálogo e sua persistência, com 100% dos testes de regressão relevantes aprovados.

**Padrão arquitetural adotado:** Portas e Adaptadores

**Táticas empacotadas:** Encapsular a dependência externa; Usar intermediário (a porta); Inverter e injetar dependência; Isolar dependência externa para teste; Adiar vinculação para tempo de configuração

Requisito funcional: publicação e atualização de produtos artesanais, incluindo fotos, técnica de produção e região de origem. Módulo afetado: microsserviço de catálogo de produtos. Atributo de qualidade: Manutenibilidade — Modificabilidade. Cenário associado: inclusão dos campos "técnica de produção" e "material utilizado" no cadastro de produtos. Critérios de aceitação: alteração limitada ao catálogo e à sua persistência, conclusão em até um ciclo de sprint e aprovação de 100% dos testes de regressão relevantes.

## Verificação

- **Teste do cenário:** Será realizado um teste de evolução do catálogo, simulando a solicitação de inclusão dos campos "técnica de produção" e "material utilizado" no cadastro dos produtos artesanais. A equipe deverá implementar a alteração, atualizar a persistência e executar os testes automatizados do catálogo e os testes de regressão relevantes dos demais serviços. A verificação será considerada bem-sucedida se a alteração for concluída em até um ciclo de sprint, sem modificar o código dos outros microsserviços e com 100% dos testes de regressão relevantes aprovados. O histórico de commits e os relatórios dos testes servirão como evidências.

---

_Gerado pelo estudo dirigido de Arquitetura de Software · ADS020 · 2026.2._
