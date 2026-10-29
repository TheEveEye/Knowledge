#!/bin/sh
set -eu

# The entrypoint runs this once, on a new Knowledge database volume.
# psql quotes the password as a SQL literal; no credential is logged.
psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=app_password="$(cat /run/secrets/db_app_password)" <<'SQL'
CREATE ROLE knowledge_api LOGIN PASSWORD :'app_password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE knowledge TO knowledge_api;
SQL
