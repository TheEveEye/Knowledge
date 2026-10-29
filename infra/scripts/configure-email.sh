#!/usr/bin/env bash
set -euo pipefail
read -r -s -p 'Paste the Resend sending API key, then press Enter: ' email_key
printf '\n'
if [[ ! "$email_key" =~ ^re_[A-Za-z0-9_-]+$ ]]; then printf 'Enter only a Resend API key.\n' >&2; exit 1; fi
printf '%s\n' "$email_key" | ssh -T -o BatchMode=yes "${1:-knowledge-pi}" 'bash /opt/knowledge/current/infra/scripts/activate-email.sh'
unset email_key
