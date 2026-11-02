#!/bin/sh
set -eu
umask 077
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
pg_dump -Fc -f "$scratch/database.dump"
pg_restore --list "$scratch/database.dump" >/dev/null
tar --exclude='*.partial' -czf - -C "$scratch" database.dump -C /var/lib/knowledge sources
