#!/usr/bin/env bash
set -euo pipefail
umask 077
export KNOWLEDGE_REMOTE_DIR=/opt/knowledge
release=$(readlink -f "$KNOWLEDGE_REMOTE_DIR/current")
source "$release/infra/scripts/compose-lib.sh"
exec 9>"$KNOWLEDGE_REMOTE_DIR/.deployment.lock"
flock -w 300 9
mkdir -p "$KNOWLEDGE_REMOTE_DIR/.secrets"
chmod 700 "$KNOWLEDGE_REMOTE_DIR/.secrets"
read -r -s -p 'Paste the Cloudflare Tunnel token, then press Enter: ' tunnel_token
printf '\n'
if [[ ! "$tunnel_token" =~ ^[A-Za-z0-9_+/=-]+$ ]]; then
  printf 'Enter only the tunnel token, not the connector installation command.\n' >&2
  exit 1
fi
temporary=$(mktemp "$KNOWLEDGE_REMOTE_DIR/.secrets/.tunnel.XXXXXX")
printf '%s' "$tunnel_token" > "$temporary"
chmod 644 "$temporary"
mv "$temporary" "$KNOWLEDGE_REMOTE_DIR/.secrets/cloudflared-token"
unset tunnel_token
knowledge_compose "$release" up -d --no-deps --force-recreate cloudflared
knowledge_compose "$release" ps cloudflared
