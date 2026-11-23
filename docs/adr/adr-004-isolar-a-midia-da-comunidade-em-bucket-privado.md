# ADR-004: Isolar a mídia da comunidade em um bucket privado

- **Status:** Proposta
- **Data:** 2026-11-23
- **Autor:** ALLYSSON FELLYPE GOMES MUNIZ (afgm@cesar.school)
- **Turma:** Embarque (segundas)
- **Projeto:** Origem · marketplace da economia criativa e do artesanato de Pernambuco

## Contexto

No Origem, artesãos podem enviar vídeos e capas para revisão antes da publicação. Enquanto o vídeo estiver em rascunho, só o autor deve conseguir abrir esses arquivos. Hoje, o Compose usa um volume local para a mídia da comunidade, embora o community-service já tenha um adaptador S3. O SeaweedFS já atende perfil e catálogo com credenciais separadas. A equipe é pequena, tem um semestre para entregar e precisa respeitar a stack e o modelo de dados acordados com as outras disciplinas, com orçamento de infraestrutura limitado.

## Preocupações

Confidencialidade dos rascunhos, isolamento de permissões, compatibilidade com a reprodução parcial, migração de arquivos, custo de infraestrutura, prazo.

## Decisão

Provisionar o bucket privado balaio-community-media no SeaweedFS existente, com uma identidade S3 exclusiva do community-service e permissões limitadas aos objetos desse bucket. Usar o adaptador S3 no perfil storage, manter o adaptador local como padrão fora desse perfil e entregar vídeos e capas pela API da comunidade.

## Justificativa

A API verifica a autoria e o estado do vídeo antes de abrir o arquivo. A política do bucket impede a leitura anônima direta e restringe o acesso das identidades de perfil e catálogo. O padrão Portas e Adaptadores permite reaproveitar a mesma regra de visibilidade nos modos local e S3, preservando as rotas e o suporte à leitura parcial.

## Consequências

A comunidade ganha isolamento de acesso sem precisar de uma nova instância de armazenamento. Em troca, a equipe precisa provisionar o bucket, manter a política de acesso e rotacionar as credenciais. O community-service continua responsável pelo tráfego de reprodução, e uma interrupção no SeaweedFS pode afetar os três serviços. Onde já houver mídia no volume local, será necessário copiar os objetos com as mesmas chaves e validar a leitura antes da troca.

## Alternativas consideradas

1. Manter o volume local no perfil storage — Preserva a configuração atual, mas deixa a autorização S3 fora dos testes de integração.
2. Usar um prefixo no bucket balaio-media — Reaproveita o bucket atual, mas exige adaptar as chaves no código ou migrá-las.
3. Entregar a mídia diretamente pelo S3 com URLs temporárias assinadas — Reduz o tráfego na API, mas uma URL compartilhada pode dar acesso ao rascunho até expirar.

## Rastreabilidade

**Atributo de qualidade:** Segurança (security) · Confidencialidade

**Cenário que originou a decisão:**

> Em um ambiente de integração em operação normal, com o S3 ativo e o vídeo e a capa de um rascunho já armazenados, um visitante sem sessão, outro artesão e os serviços de perfil e catálogo tentam ler os arquivos usando o ID do vídeo ou a chave do objeto. A API retorna 404 para o visitante e o outro artesão, e o bucket privado recusa leituras anônimas ou com credenciais de perfil e catálogo. O cenário passa se houver zero leituras indevidas e se o autor receber 200 nas leituras completas e 206 com os 10 bytes corretos na leitura parcial. Após a publicação, o visitante deve conseguir reproduzir o vídeo pela API, enquanto o acesso direto anônimo ao S3 permanece bloqueado.

**Padrão arquitetural adotado:** Portas e Adaptadores

**Táticas empacotadas:** Encapsular a dependência externa; Usar intermediário (a porta); Inverter e injetar dependência; Isolar dependência externa para teste; Adiar vinculação para tempo de configuração

community-service → VideoService.abrirMidia, ArmazenamentoMidiaPort e ArmazenamentoS3Adapter. No platform, as políticas e os testes de acesso S3 do perfil e do catálogo servem de referência. A versão inicial do ADR foi registrada em platform/docs/adr/, no commit 3b33f8d.

## Verificação

- **Teste do cenário:** Em uma pilha de integração descartável, enviar um vídeo e uma capa como rascunho. Exigir HTTP 200 para leituras completas pelo autor, 404 nos dois endpoints para o visitante e outro artesão, e 206 com Content-Range correto e os primeiros 10 bytes do vídeo ao solicitar Range: bytes=0-9 como autor. Verificar que a identidade da comunidade consegue gravar, consultar metadados, ler e excluir seus próprios objetos de teste, que acessos entre serviços são recusados e que há zero leituras indevidas. Após publicar o vídeo, confirmar que o visitante consegue reproduzi-lo pela API e que o acesso direto anônimo ao S3 continua bloqueado.

---

_Gerado pelo estudo dirigido de Arquitetura de Software · ADS020 · 2026.2._
