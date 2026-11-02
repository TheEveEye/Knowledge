#!/usr/bin/env bash
set -euo pipefail
ssh -o BatchMode=yes "${1:-knowledge-pi}" bash -s <<'REMOTE'
set -euo pipefail
export KNOWLEDGE_REMOTE_DIR=/opt/knowledge
if [[ ! -L "$KNOWLEDGE_REMOTE_DIR/previous" ]]; then printf 'No previous release is available.\n' >&2; exit 1; fi
release=$(readlink -f "$KNOWLEDGE_REMOTE_DIR/previous")
current=$(readlink -f "$KNOWLEDGE_REMOTE_DIR/current")
if [[ -f "$current/apps/worker/package.json" && ! -f "$release/apps/worker/package.json" ]]; then
  source "$current/infra/scripts/compose-lib.sh"
  knowledge_compose "$current" stop worker
fi
bash "$release/infra/scripts/apply-release.sh" "$KNOWLEDGE_REMOTE_DIR" "$release" rollback
REMOTE
