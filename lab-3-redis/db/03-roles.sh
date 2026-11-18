#!/bin/bash
# Пользователи БД с минимальными правами: приложение и экспортёр метрик.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v app_pass="$PG_APP_PASSWORD" -v exporter_pass="$PG_EXPORTER_PASSWORD" <<'SQL'
CREATE ROLE catalog_app LOGIN PASSWORD :'app_pass';
GRANT CONNECT ON DATABASE catalog TO catalog_app;
GRANT USAGE ON SCHEMA public TO catalog_app;
GRANT SELECT ON categories, products, reviews TO catalog_app;
GRANT UPDATE (price, stock, updated_at) ON products TO catalog_app;

CREATE ROLE exporter LOGIN PASSWORD :'exporter_pass';
GRANT pg_monitor TO exporter;
SQL
