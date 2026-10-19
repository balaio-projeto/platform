set -eu

psql \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=app_database="$CATALOG_DB_NAME" \
  --set=app_username="$CATALOG_DB_USERNAME" \
  --set=app_password="$CATALOG_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_username', :'app_password') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'app_database', :'app_username') \gexec
SQL