#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_dir"
if [[ ! -f .env ]]; then cp .env.example .env; fi
bash infra/scripts/init-secrets.sh "$repo_dir/.secrets"
args=(--project-name knowledge --project-directory "$repo_dir" --env-file "$repo_dir/.env"
  -f infra/compose/compose.yaml -f infra/compose/development.yaml)
case ${1:-up} in
  up)
    docker compose "${args[@]}" build api
    docker compose "${args[@]}" up -d --wait --wait-timeout 90 db
    docker compose "${args[@]}" run --rm --no-deps -T migrate
    docker compose "${args[@]}" up -d --no-deps --wait --wait-timeout 120 api caddy
    ;;
  down) docker compose "${args[@]}" down ;;
  logs) docker compose "${args[@]}" logs --tail 100 -f api caddy ;;
  *) printf 'Usage: %s [up|down|logs]\n' "$0" >&2; exit 1 ;;
esac
