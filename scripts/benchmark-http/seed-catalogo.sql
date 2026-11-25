-- Amplia o catálogo do benchmark para ~21.030 peças (cerca de 90% publicadas), como no PI-178.
-- Uso: docker exec -i bench-catalog-pg psql -U balaio_catalog_app -d balaio_catalog -v total=21030 -f - < seed-catalogo.sql
DELETE FROM reservas_peca;
DELETE FROM peca_fotos;
DELETE FROM pecas;
INSERT INTO pecas (slug, nome, artesao, territorio, tecnica, categoria, tipo, preco, desconto, disponibilidade,
                   prazo_producao_dias, historia, imagem, avaliacao, total_avaliacoes, situacao, ordem_catalogo,
                   texto_busca, materiais, autentica)
SELECT
  'peca-bench-' || g,
  'Peça artesanal ' || g,
  'Ateliê ' || (g % 300),
  (ARRAY['Vale do Jequitinhonha','Cariri','Serra da Capivara','Recôncavo','Litoral Norte','Pantanal'])[1 + g % 6],
  (ARRAY['Cerâmica','Cestaria','Tecelagem','Marcenaria','Bordado','Couro'])[1 + g % 6],
  (ARRAY['Casa & Mesa','Vestuário','Decoração','Acessórios'])[1 + g % 4],
  (ARRAY['Vaso','Cesto','Tapete','Banco','Bolsa','Luminária'])[1 + g % 6],
  round((10 + (g * 37) % 490)::numeric, 2),
  0,
  'disponivel',
  7 + g % 20,
  ARRAY['Peça feita à mão por artesãos da região.'],
  'https://exemplo.invalid/imagens/peca-' || g || '.jpg',
  round((3 + (g % 3))::numeric, 2),
  g % 50,
  CASE WHEN g % 10 = 0 THEN 'inativada' ELSE 'publicada' END,
  g,
  'peca artesanal ' || g || ' ' || (ARRAY['ceramica','cestaria','tecelagem','marcenaria','bordado','couro'])[1 + g % 6],
  '[]'::jsonb,
  false
FROM generate_series(1, :total) AS g;
SELECT count(*) AS total, count(*) FILTER (WHERE situacao = 'publicada') AS publicadas FROM pecas;
