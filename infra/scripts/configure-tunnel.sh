#!/usr/bin/env bash
set -euo pipefail
# Read locally so Cloudflare's copied Docker command can be pasted unchanged.
# Never execute the pasted command or pass its token in process arguments.
read -r -s -p 'Paste the Cloudflare token or Docker connector command, then press Enter: ' tunnel_input
printf '\n'
if [[ "$tunnel_input" =~ ^[A-Za-z0-9_+/=-]+$ ]]; then
  tunnel_token=$tunnel_input
else
  token_pattern='(^|[[:space:]])--token(=|[[:space:]]+)([A-Za-z0-9_+/=-]+)($|[[:space:]])'
  if [[ "$tunnel_input" =~ $token_pattern ]]; then
    tunnel_token=${BASH_REMATCH[3]}
  else
    printf 'No tunnel token found. Copy the Docker connector command from Cloudflare.\n' >&2
    exit 1
  fi
fi
unset tunnel_input
printf '%s\n' "$tunnel_token" | ssh -T -o BatchMode=yes "${1:-knowledge-pi}" 'bash /opt/knowledge/current/infra/scripts/activate-tunnel.sh'
unset tunnel_token
