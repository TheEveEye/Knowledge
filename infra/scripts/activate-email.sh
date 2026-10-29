#!/usr/bin/env bash
set -euo pipefail
umask 077
export KNOWLEDGE_REMOTE_DIR=/opt/knowledge
release=$(readlink -f "$KNOWLEDGE_REMOTE_DIR/current")
source "$release/infra/scripts/compose-lib.sh"
exec 9>"$KNOWLEDGE_REMOTE_DIR/.deployment.lock"
flock -w 300 9
read -r -s email_key
if [[ ! "$email_key" =~ ^re_[A-Za-z0-9_-]+$ ]]; then printf 'Invalid Resend API key.\n' >&2; exit 1; fi
temporary=$(mktemp "$KNOWLEDGE_REMOTE_DIR/.secrets/.email.XXXXXX")
printf '%s' "$email_key" > "$temporary"
chmod 644 "$temporary"
mv "$temporary" "$KNOWLEDGE_REMOTE_DIR/.secrets/email-api-key"
unset email_key
knowledge_compose "$release" up -d --no-deps --wait --wait-timeout 120 api
knowledge_compose "$release" ps api
