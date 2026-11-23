# ADR 004 — Isolar a mídia da comunidade em um bucket privado

- **Status** — Proposta
- **Data** — 23/11/2026
- **Projeto** — Projeto Integrador ORIGEM (Balaio)
- **Componentes afetados** — `platform` e `community-service`

## Contexto e atributo de qualidade

No Origem, artesãos podem enviar vídeos e capas enquanto a publicação ainda está em rascunho. Nessa etapa, só o autor deve conseguir abrir os arquivos. O `community-service` verifica a visibilidade do vídeo em `VideoService.abrirMidia` antes de acessar o armazenamento pela porta `ArmazenamentoMidiaPort`. Os mesmos endpoints entregam vídeos publicados ao público e atendem requisições parciais de reprodução.

O Compose principal guarda a mídia da comunidade no volume `community-midia`. O serviço já tem um adaptador S3 selecionável por configuração, mas o complemento `docker-compose.storage.yml` só provisiona armazenamento para perfil e catálogo. Esses dois serviços usam o mesmo SeaweedFS, com identidades separadas e permissões limitadas aos seus prefixos em `balaio-media`. Integrar a comunidade a esse ambiente exige definir onde guardar os objetos e quem pode acessá-los.

O atributo prioritário é **segurança, com foco em confidencialidade**. A leitura de um rascunho precisa continuar restrita ao autor, e as credenciais de outro serviço devem ser insuficientes para acessar esses arquivos. Restringir a escrita e a exclusão também evita que erros de configuração em um serviço alterem a mídia de outro.

## Cenário de qualidade

| Elemento | Descrição |
| --- | --- |
| Fonte | Um visitante sem sessão, um artesão que não é o autor e os serviços de perfil e catálogo com suas próprias credenciais S3. |
| Estímulo | Tentam ler o vídeo ou a capa de um rascunho cuja chave de objeto e cujo ID são conhecidos no teste. |
| Ambiente | Ambiente de integração com o adaptador S3 ativo, objetos de teste já enviados pelo autor e o bucket privado disponível. |
| Artefato | Bucket da comunidade, políticas S3 e rotas `/api/v1/videos/{id}/arquivo` e `/api/v1/videos/{id}/capa`. |
| Resposta | O armazenamento recusa acessos anônimos e de outras identidades de serviço. Pela API, visitantes e outros artesãos recebem HTTP `404` para o rascunho. O autor consegue ler o arquivo e a capa. |
| Medida | Zero leituras indevidas na matriz de testes. Os dois endpoints retornam `404` para o rascunho nos casos sem autorização, `200` em leituras completas pelo autor e `206` em leitura parcial válida do vídeo pelo autor. Após publicação, o visitante consegue reproduzir o vídeo pela API e a leitura anônima direta no S3 continua bloqueada. |

## Decisão

Provisionar um bucket privado `balaio-community-media` na instância SeaweedFS já usada pelo Compose. Criar uma identidade S3 exclusiva da comunidade, com `GetObject`, `PutObject` e `DeleteObject` limitados a objetos desse bucket. A leitura de metadados via `HeadObject`, usada pelo adaptador, deve ser coberta pelo teste da política. Reservar criação, administração e configuração de bucket à identidade de provisionamento.

Configurar `COMMUNITY_MIDIA_ARMAZENAMENTO=s3` no perfil `storage` e fornecer as variáveis com prefixo `COMMUNITY_S3_` somente ao `community-service` entre os serviços da aplicação. Manter o adaptador local como padrão nas execuções sem o perfil de armazenamento. Quando o modo S3 estiver ativo, exigir a configuração completa na inicialização para que valores obrigatórios ausentes sejam detectados na inicialização, com uso do volume local somente por configuração explícita ou padrão fora do perfil.

Manter o `community-service` como intermediário da entrega. Seu controle de visibilidade continua determinando se o leitor pode acessar o rascunho ou a publicação. O serviço conserva as rotas atuais e repassa o intervalo de bytes ao adaptador S3 quando o player solicita uma leitura parcial. A identidade S3 autoriza o serviço a operar no bucket, enquanto a autorização da aplicação determina quais usuários podem ler cada vídeo.

## Justificativa

O bucket dedicado permite aplicar uma política de acesso por serviço e conservar as chaves de objeto já persistidas, geradas por tipo de mídia e ID do vídeo. Também facilita administrar os vídeos e as capas como um conjunto separado sem subir outro servidor S3. A arquitetura de Portas e Adaptadores existente concentra a troca de armazenamento na configuração e no adaptador. A decisão aplica privilégio mínimo à identidade de serviço e verifica a autorização no ponto de entrega ao usuário.

## Alternativas consideradas

| Alternativa | Benefício | Custo ou compromisso |
| --- | --- | --- |
| Manter o volume local no perfil `storage` | Preserva a configuração atual e mantém os vídeos disponíveis no ambiente de um único host. | O fluxo integrado deixa de exercitar a autorização S3 e o comportamento de leitura parcial usado no armazenamento de objetos. |
| Usar um prefixo exclusivo em `balaio-media` | Reaproveita o mesmo bucket e segue o modelo de perfil e catálogo. | As chaves atuais precisariam receber um prefixo da comunidade no adaptador ou em uma migração. A política precisaria ser testada também nos limites do prefixo. |
| Entregar URLs temporárias assinadas pelo serviço | Transfere o tráfego de reprodução ao storage e reduz a carga no serviço. | A URL pode ser usada por quem a receber até seu vencimento. Seria preciso definir expiração, lidar com mudanças de visibilidade durante esse prazo e ajustar o contrato de entrega. |

## Consequências

- Um erro de permissão ou de configuração no perfil ou no catálogo tem alcance limitado pelas políticas de armazenamento. Uma credencial da comunidade ainda dá acesso aos objetos da própria comunidade, inclusive rascunhos, e sua rotação precisa ser tratada pelo provisionamento.
- O Compose passa a exigir mais um bucket, uma identidade e uma política. A instância SeaweedFS continua sendo uma dependência compartilhada, e uma interrupção nela pode afetar os três serviços.
- O `community-service` continua no caminho dos bytes de vídeo. O suporte a `Range` preserva a leitura em partes e o serviço segue responsável pelo tráfego de reprodução.
- O volume local e o bucket guardam arquivos em locais distintos. Para adotar o modo S3 em um ambiente com mídia existente, copiar os objetos referenciados pelo banco com as mesmas chaves, verificar integridade e leitura antes da troca e preservar o volume de origem durante a validação.

## Verificação

1. **Matriz de autorização S3.** Usar uma pilha descartável com um objeto de vídeo e uma capa pré-carregados no bucket privado. Confirmar que a identidade da comunidade grava, consulta metadados, lê e remove seus próprios objetos de teste. Exigir recusa para leitura, escrita e exclusão cruzadas entre a identidade da comunidade e as de perfil e catálogo. Verificar que a leitura anônima é recusada e que nenhuma tentativa indevida altera os objetos de teste.
2. **Visibilidade pela API.** Criar um rascunho com vídeo e capa pelo `community-service`. Confirmar `200` para o dono e `404` para o visitante e outro artesão nos dois endpoints. Pedir `Range: bytes=0-9` como dono e exigir `206`, `Content-Range` correto e dez bytes iguais aos do arquivo enviado. Publicar e confirmar leitura pública pela API, com leitura direta anônima no S3 ainda recusada.
3. **Configuração e adoção.** Validar o Compose com e sem o perfil `storage`. Fazer o serviço subir em modo S3 com a configuração completa e verificar a falha de inicialização com uma configuração obrigatória ausente. Para um ambiente com mídia anterior, comparar chaves e conteúdo após a cópia e repetir a verificação pela API antes de concluir a troca.

A proposta será considerada validada quando as verificações passarem no ambiente isolado. Os testes de acesso do perfil e do catálogo servem como base para a matriz da comunidade.

## Rastreabilidade

- [Configuração atual do Compose](../../docker-compose.yml) e [complemento de armazenamento](../../docker-compose.storage.yml).
- [Política S3 do perfil](../../storage/profile-s3-policy.json) e [política S3 do catálogo](../../storage/catalog-s3-policy.json).
- [Testes de acesso do perfil](../../storage/test-profile-access.sh) e [testes de acesso do catálogo](../../storage/test-catalog-access.sh).
- No repositório `community-service`, consultar a seção “Armazenamento dos arquivos” do README e as classes `VideoService`, `ArmazenamentoMidiaPort` e `ArmazenamentoS3Adapter` no módulo `video`.
