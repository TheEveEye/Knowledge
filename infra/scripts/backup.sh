#!/usr/bin/env bash
set -euo pipefail
host=${1:-knowledge-pi}
destination=${2:-"$HOME/Backups/knowledge"}
mkdir -p "$destination"
chmod 700 "$destination"
filename="knowledge-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
umask 077
ssh -o BatchMode=yes "$host" 'set -e; export KNOWLEDGE_REMOTE_DIR=/opt/knowledge; exec 9>"$KNOWLEDGE_REMOTE_DIR/.deployment.lock"; flock -s -w 300 9; release=$(readlink -f "$KNOWLEDGE_REMOTE_DIR/current"); . "$release/infra/scripts/compose-lib.sh"; knowledge_compose "$release" run --rm --no-deps -T backup' > "$destination/$filename.partial"
mv "$destination/$filename.partial" "$destination/$filename"
shasum -a 256 "$destination/$filename" > "$destination/$filename.sha256"
ssh -o BatchMode=yes "$host" 'set -e; cd /opt/knowledge; tar -czf - .secrets .env config' > "$destination/$filename.config.partial"
mv "$destination/$filename.config.partial" "$destination/$filename.config.tar.gz"
shasum -a 256 "$destination/$filename.config.tar.gz" > "$destination/$filename.config.tar.gz.sha256"
printf 'Database, sources, and protected configuration backups saved: %s\n' "$destination/$filename"
