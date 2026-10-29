#!/usr/bin/env bash
set -euo pipefail
umask 077

secret_dir=${1:?Usage: init-secrets.sh SECRETS_DIRECTORY}
mkdir -p "$secret_dir"
chmod 700 "$secret_dir"
for secret in db-owner-password db-app-password auth-secret; do
  destination="$secret_dir/$secret"
  if [[ ! -e "$destination" ]]; then
    temporary=$(mktemp "$secret_dir/.password.XXXXXX")
    openssl rand -hex 32 > "$temporary"
    mv "$temporary" "$destination"
  fi
  [[ -s "$destination" ]] || { printf 'Empty credential file: %s\n' "$destination" >&2; exit 1; }
  # The parent directory is private. Read-only container mounts must be
  # readable by both node (uid 1000) and postgres (image-defined uid).
  chmod 644 "$destination"
done
