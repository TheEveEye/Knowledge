#!/bin/sh
set -eu
PGPASSWORD=$(cat /run/secrets/db_password)
export PGPASSWORD
# Keep the cleanup exclusion lock in this live psql session while the shell archive runs.
exec psql -Xq -v ON_ERROR_STOP=1 <<'SQL'
\o /dev/null
SELECT pg_advisory_lock(782115903);
\! /bin/sh /opt/knowledge/backup-archive.sh
\if :SHELL_ERROR
  \quit 1
\endif
SELECT pg_advisory_unlock(782115903);
SQL
