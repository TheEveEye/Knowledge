#!/usr/bin/env bash

knowledge_compose() {
  local release_dir=$1
  shift
  local args=(--project-name knowledge --project-directory "$release_dir"
    --env-file "$KNOWLEDGE_REMOTE_DIR/.env" --env-file "$release_dir/.env.release"
    -f "$release_dir/infra/compose/compose.yaml")
  if [[ -s "$KNOWLEDGE_REMOTE_DIR/.secrets/cloudflared-token" ]]; then
    args+=(-f "$release_dir/infra/compose/tunnel.yaml")
  fi
  if [[ -s "$KNOWLEDGE_REMOTE_DIR/.secrets/email-api-key" && -f "$release_dir/infra/compose/email.yaml" ]]; then
    args+=(-f "$release_dir/infra/compose/email.yaml")
  fi
  docker compose "${args[@]}" "$@"
}

knowledge_front_services() {
  FRONT_SERVICES=(api caddy)
  if [[ -s "$KNOWLEDGE_REMOTE_DIR/.secrets/cloudflared-token" ]]; then
    FRONT_SERVICES+=(cloudflared)
  fi
}
