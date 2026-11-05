-- Executar somente após backup verificado. Preserva as tabelas antigas para auditoria.
\set ON_ERROR_STOP on
BEGIN;
DO $guard$
BEGIN
    IF (SELECT count(*) FROM flyway_schema_history) <> 1 OR NOT EXISTS (
        SELECT 1 FROM flyway_schema_history
        WHERE version = '1' AND script = 'V1__accounts_and_password_recovery.sql'
          AND checksum = 449745879 AND success
    ) THEN
        RAISE EXCEPTION 'Histórico Flyway legado inesperado; migração cancelada';
    END IF;
    IF to_regclass('public.contas') IS NOT NULL
       OR to_regclass('public.legacy_accounts') IS NOT NULL
       OR to_regclass('public.legacy_password_recovery') IS NOT NULL
       OR to_regclass('public.legacy_account_sessions') IS NOT NULL THEN
        RAISE EXCEPTION 'Tabelas de destino ou de arquivo já existem; migração cancelada';
    END IF;
    IF EXISTS (SELECT 1 FROM accounts WHERE name <> btrim(name) OR name = ''
               OR length(name) > 240 OR email <> lower(btrim(email))
               OR length(email) > 254 OR email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
               OR role NOT IN ('comprador', 'artesao', 'admin')
               OR ('{bcrypt}' || password_hash) !~ '^\{bcrypt\}\$2[aby]\$(0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{53}$') THEN
        RAISE EXCEPTION 'Conta incompatível com o esquema novo; migração cancelada';
    END IF;
END $guard$;

ALTER TABLE accounts RENAME TO legacy_accounts;
ALTER TABLE account_sessions RENAME TO legacy_account_sessions;
ALTER TABLE password_recovery RENAME TO legacy_password_recovery;
ALTER TABLE legacy_password_recovery RENAME CONSTRAINT password_recovery_pkey TO legacy_password_recovery_pkey;
ALTER TABLE legacy_password_recovery RENAME CONSTRAINT password_recovery_token_hash_key TO legacy_password_recovery_token_hash_key;
ALTER INDEX password_recovery_account_active_idx RENAME TO legacy_password_recovery_account_active_idx;

CREATE TABLE contas (
    id UUID PRIMARY KEY,
    nome VARCHAR(240) NOT NULL,
    email VARCHAR(254) NOT NULL,
    senha_hash VARCHAR(255) NOT NULL,
    papel VARCHAR(16) NOT NULL,
    troca_senha_obrigatoria BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT ck_contas_nome CHECK (nome = btrim(nome) AND nome <> ''),
    CONSTRAINT ck_contas_email CHECK (
        email = lower(btrim(email))
        AND email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    ),
    CONSTRAINT ck_contas_senha_hash CHECK (
        senha_hash ~ '^\{bcrypt\}\$2[aby]\$(0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{53}$'
    ),
    CONSTRAINT ck_contas_papel CHECK (papel IN ('comprador', 'artesao', 'admin'))
);
CREATE UNIQUE INDEX uk_contas_email_normalizado ON contas (lower(btrim(email)));
INSERT INTO contas (id, nome, email, senha_hash, papel, troca_senha_obrigatoria)
SELECT id, name, email, '{bcrypt}' || password_hash, role, FALSE FROM legacy_accounts;

DO $verify$
BEGIN
    IF (SELECT count(*) FROM contas) <> (SELECT count(*) FROM legacy_accounts)
       OR EXISTS (SELECT id FROM legacy_accounts EXCEPT SELECT id FROM contas) THEN
        RAISE EXCEPTION 'Cópia de contas incompleta; migração cancelada';
    END IF;
END $verify$;
-- V1 atual já está materializada acima. A troca do registro é estritamente guardada
-- pelo checksum e pelo esquema legado verificados nesta transação.
UPDATE flyway_schema_history
SET description = 'create contas', script = 'V1__create_contas.sql', checksum = -1577187942
WHERE version = '1';
COMMIT;
