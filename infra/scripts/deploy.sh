#!/usr/bin/env bash
set -euo pipefail
umask 077
host=${1:-knowledge-pi}
remote_dir=/opt/knowledge
repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_dir"
[[ -f package-lock.json ]] || { printf 'Generate package-lock.json before deploying.\n' >&2; exit 1; }
temporary_dir=$(mktemp -d)
archive="$temporary_dir/source.tar.gz"
trap '[[ ! -f "$archive" ]] || rm "$archive"; rmdir "$temporary_dir"' EXIT
COPYFILE_DISABLE=1 tar --no-xattrs --no-acls \
  --exclude=node_modules --exclude=dist --exclude=.DS_Store --exclude=.secrets \
  -czf "$archive" package.json package-lock.json .dockerignore apps/api infra
source_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
revision=$(git rev-parse --short=12 HEAD)
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then revision="$revision-dirty-${source_sha:0:12}"; fi
release="$(date -u +%Y%m%dT%H%M%SZ)-${source_sha:0:12}"

ssh -o BatchMode=yes "$host" 'if [ ! -d /opt/knowledge ]; then sudo -n install -d -o "$(id -u)" -g "$(id -g)" -m 750 /opt/knowledge; fi; mkdir -p /opt/knowledge/releases /opt/knowledge/.incoming; chmod 700 /opt/knowledge/.incoming'
scp "$archive" "$host:$remote_dir/.incoming/$release.tar.gz"
ssh -o BatchMode=yes "$host" bash -s -- "$release" "$source_sha" "$revision" <<'REMOTE'
set -euo pipefail
umask 077
release=$1
source_sha=$2
revision=$3
root=/opt/knowledge
archive="$root/.incoming/$release.tar.gz"
printf '%s  %s\n' "$source_sha" "$archive" | sha256sum --check --status
release_dir="$root/releases/$release"
mkdir "$release_dir"
tar -xzf "$archive" -C "$release_dir"
printf 'KNOWLEDGE_API_IMAGE=knowledge-api:%s\nAPP_REVISION=%s\nSOURCE_SHA256=%s\n' \
  "$release" "$revision" "$source_sha" > "$release_dir/.env.release"
chmod -R u=rwX,go=rX "$release_dir"
chmod 600 "$release_dir/.env.release"
rm "$archive"
bash "$release_dir/infra/scripts/apply-release.sh" "$root" "$release_dir"
REMOTE
