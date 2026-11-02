# Backend deployment

The Knowledge backend runs independently of Shrimp and Portainer on the Raspberry Pi. Its Docker Compose project is named `knowledge`.

## Services

| Service | Responsibility |
| --- | --- |
| `db` | PostgreSQL 18; persistent `knowledge_pgdata` volume |
| `migrate` | One-shot Drizzle migration process using the database owner credential |
| `api` | Fastify application API and interactive AI using the application role |
| `worker` | Durable source/import/Recall processing; shares private `knowledge_source_files` storage with the API |
| `backup` | Operations-profile database and source archive under the cleanup lock |
| `caddy` | Forwards `/api/*` to Fastify without stripping the prefix and serves the Password AutoFill association file |
| `cloudflared` | Optional dedicated Knowledge tunnel, enabled after its token is installed |

Email sign-in uses Resend's HTTPS API rather than a separate mail container. The `email.yaml` overlay is included only after the private sending key is installed. See [email sign-in](Email-Sign-In.md) for domain verification and the activation command; the API remains ready while email delivery is disabled.

Only Caddy is published on the Pi, at `127.0.0.1:8088`. The API and database are private to the Knowledge network. The public origin is `https://knowledge.kiwiapps.dev`; Cloudflare supplies public HTTPS and the encrypted outbound tunnel. The connector uses HTTP to reach Caddy on the private Docker network.

The site root currently returns 404. A future web application will use `/`, while application endpoints retain `/api/`.

## Deploy a source release

Run from this repository on the Mac:

```sh
./infra/scripts/deploy.sh knowledge-pi
```

This initial deployment path uploads an explicit source archive and builds the ARM64 image on the Pi. It does not require publishing the new application to a registry. A later image-publishing workflow can replace the build step while retaining the Compose layout and release records.

The script:

1. Archives only backend and infrastructure source, excluding installed dependencies and generated output. No local credential files or iOS source are uploaded.
2. Verifies the archive checksum on the Pi and creates a timestamped release under `/opt/knowledge/releases/`.
3. Records its source checksum, base Git revision, and image tag in `.env.release`. Uncommitted source is explicitly marked `dirty` with a source checksum.
4. Generates database passwords, authentication secret, and AI-encryption key only if absent. Existing credentials are retained.
5. Creates a database/source backup before migrating an existing cloud deployment (database-only for a preceding account-only release), builds contracts/backend/API/worker, and applies additive migrations.
6. Starts the API, worker, and Caddy, waiting for API readiness and the worker heartbeat health check.
7. Updates `/opt/knowledge/current` after successful startup and preserves the previous release for application rollback.

The Pi must provide Docker, Compose, SSH, `flock`, and OpenSSL. Initial creation of `/opt/knowledge` requires sudo; routine deployments use the existing directory and the Docker group. Release application is serialized with a filesystem lock.

The database and gateway images follow supported major tags and are pulled if absent. Updating existing infrastructure images is a separate maintenance action (`docker compose pull db caddy` with the documented release environment), rather than an automatic side effect of deploying API code. API releases have unique local image tags and recorded image IDs. Images and previous releases are retained for recovery.

The Pi retains its database bootstrap script at `/opt/knowledge/config/postgres-init.sh`. Its bind source remains stable across API releases so changing the release directory does not unnecessarily recreate PostgreSQL. Changes to an existing database belong in migrations, not in that first-install script.

## Operations

```sh
./infra/scripts/status.sh knowledge-pi
./infra/scripts/logs.sh knowledge-pi api
./infra/scripts/logs.sh knowledge-pi db
./infra/scripts/backup.sh knowledge-pi
./infra/scripts/rollback.sh knowledge-pi
```

Backups default to `~/Backups/knowledge` on the Mac, include a SHA-256 sidecar, and contain `database.dump` (PostgreSQL custom format) plus `sources/`. Cleanup is blocked while the archive is created. A separate protected `.config.tar.gz` includes `.secrets`, `.env`, and configuration; retain both archives and their checksums together. Deployment backups also remain under `/opt/knowledge/backups/` on the Pi.

Application rollback switches to the previous image and configuration; it does not reverse migrations or restore database contents. Automatic startup-failure recovery also retains migrations. Data restoration is a separate operation, with an explicit backup and recovery plan.

Runtime credentials live under `/opt/knowledge/.secrets/`, whose directory permissions are `0700`. Individual mounted files are readable to their containers' different user IDs. Keep the containing directory private and include credentials in an appropriately protected disaster-recovery backup; a database dump alone does not preserve the application's external credentials.

The API additionally mounts `auth-secret` for Knowledge session signatures. API and worker mount `ai-encryption-key` for encrypted AI credentials. Never replace either key during routine releases. Its public authentication origin defaults to `https://knowledge.kiwiapps.dev`; trusted extra origins are explicitly configured with `AUTH_TRUSTED_ORIGINS`. The production Compose configuration trusts Cloudflare's client-IP header because API ports remain private behind the tunnel. See [user accounts](User-Accounts.md) for the endpoint contract and development settings. Never replace the authentication secret during routine deployment.

Do not use `docker compose down --volumes` or prune named volumes. Compose definitions remain in Git and on disk; Portainer provides visibility into the externally managed stack.

## Cloud processing and funding

See [Cloud library](Cloud-Library.md) for server ownership, worker leases, funding, operational metrics, and private storage. `CHATGPT_SELF_HOSTED_ENABLED=true` is restricted to personal self-hosting; leave it disabled for broader hosted service use. The optional `ai-api.yaml` overlay is selected only when the private `.secrets/openai-api-key` file exists. Set `AI_API_DAILY_REQUEST_LIMIT` explicitly in `/opt/knowledge/.env` before allowing API-funded inference; the default is zero. Funding is selected per operation and never falls back automatically.

Source storage is a named volume, mounted only into API, worker, and the backup service. Caddy has no mount or file-serving route for sources. Preserve both `knowledge_pgdata` and `knowledge_source_files`. Restore the protected configuration alongside the database and source archive so encrypted provider grants remain readable. Stop API and worker before a restoration, restore into the existing volumes with their ownership preserved, then resume the matching release. Restoration is a separate explicit operation.

## Cloudflare and Name.com

The authoritative nameservers observed for `kiwiapps.dev` are:

```text
harlee.ns.cloudflare.com
walt.ns.cloudflare.com
```

This means Cloudflare currently manages DNS. Name.com is the registrar; no registrar DNS or nameserver change is needed for this hostname.

In Cloudflare, open **Networking → Tunnels** (some dashboards show **Zero Trust → Networks → Connectors / Cloudflare Tunnels**):

The `knowledge` tunnel has already been created with ID `122e8f85-0262-4422-a3e4-47e5a04aae94`. Its published application route and DNS record for `knowledge.kiwiapps.dev` are configured as described below. The connector token is installed on the Pi, and the Compose connector is running there with four registered Cloudflare connections. The following steps document setup and token replacement.

1. Create a remotely managed **Cloudflared** tunnel named `knowledge`.
2. Open that tunnel's **Overview** and select **Docker** under the connector installation instructions. Leave the **Copy to clipboard** button available.
3. From the Mac repository root, run:

   ```sh
   ./infra/scripts/configure-tunnel.sh knowledge-pi
   ```

   At the hidden terminal prompt, click Cloudflare's **Copy to clipboard** button, then paste the complete Docker connector command into the prompt and press Enter. A token alone is also accepted. The script extracts the token without executing the pasted command and sends it through SSH standard input. It is stored in the Pi's private credential directory and mounted as a file; it is not put into Git, command arguments, or this chat. The script starts the existing Compose connector definition. Do not separately run the dashboard's example Docker command.

4. Add a **Published application route / Public hostname** on that tunnel:

   | Field | Value |
   | --- | --- |
   | Subdomain | `knowledge` |
   | Domain | `kiwiapps.dev` |
   | Path | Leave empty |
   | Service type | `HTTP` |
   | Service URL | `knowledge-caddy:80` |

   The complete service address is `http://knowledge-caddy:80`. This name resolves inside the Knowledge Docker network; `localhost` in the connector would refer to the connector itself.

5. Allow Cloudflare to create the hostname's proxied DNS record. If manual creation is required, use a proxied CNAME from `knowledge` to `<TUNNEL_ID>.cfargotunnel.com`, with automatic TTL. Do not create an A record pointing to the Pi's private IP.
6. The public endpoints will be `https://knowledge.kiwiapps.dev/api/status` and `https://knowledge.kiwiapps.dev/api/ready` once the connector is healthy and DNS and the edge certificate are active.

No router port forwarding is required. Shrimp's tunnel, Portainer, and their DNS records do not need changing. Do not put an interactive Cloudflare Access login in front of the entire API if native clients are expected to connect; Knowledge manages its own application sessions.

The web page root can be published through the same hostname later, without another API hostname or a cross-origin browser configuration.

Official references: [Cloudflare Tunnel setup](https://developers.cloudflare.com/tunnel/get-started/), [tunnel run parameters](https://developers.cloudflare.com/tunnel/reference/run-parameters/).

## Local access before DNS is configured

From the Mac:

```sh
ssh -N -L 8088:127.0.0.1:8088 knowledge-pi
```

Then open `http://127.0.0.1:8088/api/status` in a browser. This uses SSH and requires no public hostname. Operational container health checks are part of the deployed stack; the repository contains no tests or test-only infrastructure.
