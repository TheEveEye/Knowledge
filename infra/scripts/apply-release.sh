#!/usr/bin/env bash
set -euo pipefail
umask 077
export KNOWLEDGE_REMOTE_DIR=${1:?Deployment root required}
release_dir=${2:?Release directory required}
mode=${3:-deploy}
source "$release_dir/infra/scripts/compose-lib.sh"

# Serialize all deployments, migrations, rollbacks, and tunnel activation.
exec 9>"$KNOWLEDGE_REMOTE_DIR/.deployment.lock"
flock -w 300 9
previous=''
if [[ -L "$KNOWLEDGE_REMOTE_DIR/current" ]]; then
  previous=$(readlink -f "$KNOWLEDGE_REMOTE_DIR/current")
fi

if [[ "$mode" == deploy ]]; then
  bash "$release_dir/infra/scripts/init-secrets.sh" "$KNOWLEDGE_REMOTE_DIR/.secrets"
  if [[ ! -e "$KNOWLEDGE_REMOTE_DIR/.env" ]]; then
    printf 'KNOWLEDGE_SECRETS_DIR=%s/.secrets\nKNOWLEDGE_HTTP_PORT=8088\nLOG_LEVEL=info\n' \
      "$KNOWLEDGE_REMOTE_DIR" > "$KNOWLEDGE_REMOTE_DIR/.env"
  fi
  # Keep this bind source stable across API releases. A release-specific
  # bootstrap path would unnecessarily recreate PostgreSQL on every deploy.
  mkdir -p "$KNOWLEDGE_REMOTE_DIR/config"
  if [[ ! -e "$KNOWLEDGE_REMOTE_DIR/config/postgres-init.sh" ]]; then
    cp "$release_dir/infra/postgres/init-app-user.sh" "$KNOWLEDGE_REMOTE_DIR/config/postgres-init.sh"
    chmod 755 "$KNOWLEDGE_REMOTE_DIR/config/postgres-init.sh"
  fi
  if ! grep -q '^KNOWLEDGE_POSTGRES_INIT=' "$KNOWLEDGE_REMOTE_DIR/.env"; then
    printf 'KNOWLEDGE_POSTGRES_INIT=%s/config/postgres-init.sh\n' "$KNOWLEDGE_REMOTE_DIR" >> "$KNOWLEDGE_REMOTE_DIR/.env"
  fi
  if [[ -n "$previous" ]]; then
    mkdir -p "$KNOWLEDGE_REMOTE_DIR/backups"
    backup="$KNOWLEDGE_REMOTE_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)-before-migration.dump"
    knowledge_compose "$previous" exec -T db pg_dump -U knowledge_owner -d knowledge -Fc > "$backup"
    knowledge_compose "$previous" exec -T db pg_restore --list < "$backup" > /dev/null
  fi
  docker build --pull --build-arg "APP_REVISION=$(sed -n 's/^APP_REVISION=//p' "$release_dir/.env.release")" \
    -t "knowledge-api:$(basename "$release_dir")" -f "$release_dir/apps/api/Dockerfile" "$release_dir"
  # Image upgrades for existing infrastructure are a separate maintenance action.
  knowledge_compose "$release_dir" pull --policy missing db caddy
  knowledge_compose "$release_dir" up -d --no-deps --wait --wait-timeout 90 db
  knowledge_compose "$release_dir" run --rm --no-deps -T migrate
elif [[ "$mode" != rollback ]]; then
  printf 'Unknown deployment mode\n' >&2
  exit 1
fi

knowledge_front_services
if ! knowledge_compose "$release_dir" up -d --no-deps --wait --wait-timeout 120 "${FRONT_SERVICES[@]}"; then
  if [[ -n "$previous" && "$previous" != "$release_dir" ]]; then
    printf 'Startup failed; restoring the previous application image. Database migrations are retained.\n' >&2
    knowledge_compose "$previous" up -d --no-deps --wait --wait-timeout 120 "${FRONT_SERVICES[@]}"
  fi
  exit 1
fi

if [[ -n "$previous" && "$previous" != "$release_dir" ]]; then
  ln -sfn "$previous" "$KNOWLEDGE_REMOTE_DIR/previous"
fi
ln -sfn "$release_dir" "$KNOWLEDGE_REMOTE_DIR/current"
docker image inspect --format '{{.Id}}' "$(sed -n 's/^KNOWLEDGE_API_IMAGE=//p' "$release_dir/.env.release")" \
  > "$release_dir/image-id.txt"
printf 'Active release: %s\n' "$(basename "$release_dir")"
knowledge_compose "$release_dir" ps
