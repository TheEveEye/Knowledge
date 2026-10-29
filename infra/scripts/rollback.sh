#!/usr/bin/env bash
set -euo pipefail
ssh -o BatchMode=yes "${1:-knowledge-pi}" 'set -e; root=/opt/knowledge; if [ ! -L "$root/previous" ]; then printf "No previous release is available.\n" >&2; exit 1; fi; release=$(readlink -f "$root/previous"); bash "$release/infra/scripts/apply-release.sh" "$root" "$release" rollback'
