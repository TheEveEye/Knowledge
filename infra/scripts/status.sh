#!/usr/bin/env bash
set -euo pipefail
ssh -o BatchMode=yes "${1:-knowledge-pi}" 'set -e; export KNOWLEDGE_REMOTE_DIR=/opt/knowledge; release=$(readlink -f "$KNOWLEDGE_REMOTE_DIR/current"); . "$release/infra/scripts/compose-lib.sh"; printf "Release: %s\n" "$(basename "$release")"; cat "$release/.env.release"; knowledge_compose "$release" ps'
