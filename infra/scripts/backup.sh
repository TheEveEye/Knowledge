#!/usr/bin/env bash
set -euo pipefail
host=${1:-knowledge-pi}
destination=${2:-"$HOME/Backups/knowledge"}
mkdir -p "$destination"
chmod 700 "$destination"
filename="knowledge-$(date -u +%Y%m%dT%H%M%SZ).dump"
umask 077
ssh -o BatchMode=yes "$host" 'set -e; export KNOWLEDGE_REMOTE_DIR=/opt/knowledge; release=$(readlink -f "$KNOWLEDGE_REMOTE_DIR/current"); . "$release/infra/scripts/compose-lib.sh"; knowledge_compose "$release" exec -T db pg_dump -U knowledge_owner -d knowledge -Fc' > "$destination/$filename.partial"
mv "$destination/$filename.partial" "$destination/$filename"
shasum -a 256 "$destination/$filename" > "$destination/$filename.sha256"
printf 'Database backup saved: %s\n' "$destination/$filename"
