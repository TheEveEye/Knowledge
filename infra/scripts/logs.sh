#!/usr/bin/env bash
set -euo pipefail
service=${2:-api}
case "$service" in api|db|caddy|cloudflared) ;; *) printf 'Unknown service\n' >&2; exit 1 ;; esac
ssh -o BatchMode=yes "${1:-knowledge-pi}" bash -s -- "$service" <<'REMOTE'
set -euo pipefail
export KNOWLEDGE_REMOTE_DIR=/opt/knowledge
release=$(readlink -f "$KNOWLEDGE_REMOTE_DIR/current")
source "$release/infra/scripts/compose-lib.sh"
knowledge_compose "$release" logs --tail 100 -f "$1"
REMOTE
