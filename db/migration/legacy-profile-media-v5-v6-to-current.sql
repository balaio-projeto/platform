-- Compatibilidade exclusiva: banco local com V5/V6 de midia anteriores a develop.
-- Executar somente apos backup e validacao em copia. Nao altera checksums existentes.
\set ON_ERROR_STOP on
BEGIN;
LOCK TABLE flyway_schema_history IN EXCLUSIVE MODE;
DO $guard$
BEGIN
 IF (SELECT count(*) FROM flyway_schema_history) <> 6
 OR (SELECT count(*) FROM flyway_schema_history WHERE success AND
 (version,script,checksum) IN (
 ('1','V1__create_contas.sql',-1577187942),
 ('2','V2__create_controle_administracao.sql',972723959),
 ('3','V3__create_password_recovery.sql',866612377),
 ('4','V4__create_perfis_artesao.sql',406043366),
 ('5','V5__create_midias_perfil.sql',584367059),
 ('6','V6__protect_media_cleanup.sql',704505435))) <> 6 THEN
 RAISE EXCEPTION 'Historico diferente do legado esperado; nenhuma alteracao aplicada';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
 AND table_name='midias_perfil' AND column_name='proxima_tentativa')
 OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='midias_perfil'::regclass
 AND conname='fk_midias_perfil_perfil' AND confdeltype='r') THEN
 RAISE EXCEPTION 'Esquema de midia inesperado';
 END IF;
END $guard$;
CREATE TEMP TABLE compat_counts AS SELECT
 (SELECT count(*) FROM contas) AS contas,
 (SELECT count(*) FROM midias_perfil) AS midias,
 (SELECT count(*) FROM password_recovery) AS recuperacoes;
-- V7/V8 atuais tem exatamente os mesmos checksums das antigas V5/V6.
UPDATE flyway_schema_history SET version='7', script='V7__create_midias_perfil.sql'
 WHERE version='5';
UPDATE flyway_schema_history SET version='8', script='V8__protect_media_cleanup.sql'
 WHERE version='6';
-- Aplica a V5 atual integralmente; registra seu checksum verificado.
UPDATE perfis_artesao
SET slug = 'artesao-' || conta_id::text
WHERE slug <> 'artesao-' || conta_id::text;

INSERT INTO perfis_artesao (id, conta_id, slug, nome, atelie)
SELECT gen_random_uuid(),
       c.id,
       'artesao-' || c.id::text,
       c.nome,
       left('Ateliê de ' || c.nome, 240)
FROM contas c
WHERE c.papel = 'artesao'
  AND NOT EXISTS (SELECT 1 FROM perfis_artesao p WHERE p.conta_id = c.id);

INSERT INTO flyway_schema_history
(installed_rank,version,description,type,script,checksum,installed_by,execution_time,success)
SELECT max(installed_rank)+1,'5','perfis artesao slug da conta','SQL',
 'V5__perfis_artesao_slug_da_conta.sql',1807479742,current_user,0,true
FROM flyway_schema_history;
DO $verify$
BEGIN
 IF EXISTS (SELECT 1 FROM compat_counts WHERE
 contas<>(SELECT count(*) FROM public.contas) OR midias<>(SELECT count(*) FROM midias_perfil)
 OR recuperacoes<>(SELECT count(*) FROM password_recovery)) THEN
 RAISE EXCEPTION 'Contagens alteradas; revertendo';
 END IF;
 IF EXISTS (SELECT 1 FROM perfis_artesao WHERE slug <> 'artesao-' || conta_id::text) THEN
 RAISE EXCEPTION 'Slug incompatível';
 END IF;
END $verify$;
COMMIT;
