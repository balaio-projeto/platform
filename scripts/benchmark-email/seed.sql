-- Semeia :n pedidos com um e-mail pendente cada (evento pagamento_confirmado, destinatário comprador).
-- Uso: docker exec -i bench-pg psql -U bench -d balaio_commerce -v n=100 -f - < seed.sql
TRUNCATE pedidos CASCADE;
INSERT INTO pedidos (id, comprador_id, artesao_id, estado, chave_checkout, fingerprint_checkout, endereco,
                     frete_id, frete, total, meio, rastreio, transportadora)
SELECT gen_random_uuid(), '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002',
       'confirmado', 'bench-' || g, repeat('a', 64), '{}'::jsonb, 'padrao', 0, 10.00, 'checkout_pro',
       'BR123456789BR', 'Correios'
FROM generate_series(1, :n) AS g;
INSERT INTO pedido_emails (pedido_id, evento, destinatario, estado, proxima_tentativa_em)
SELECT id, 'pagamento_confirmado', 'comprador', 'pendente', now() FROM pedidos;
SELECT count(*) AS pendentes FROM pedido_emails WHERE estado = 'pendente';
