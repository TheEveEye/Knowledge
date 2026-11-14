# BERMUN project handoff

Prepared on 14 November 2026. This document is self-contained and can be copied into a new project as `docs/Deployment.md`.

## Requested application

- Project name: **BERMUN**; infrastructure identifier: `bermun`.
- Frontend: **React**.
- Backend: **Express**.
- Database: **PostgreSQL**.
- Production URL: **https://bermun.kiwiapps.dev**.
- All application services and the database run on the existing Raspberry Pi. Cloudflare provides public DNS, HTTPS, and the tunnel to the Pi.
- Build this in a separate repository and deploy it as a separate Docker Compose project. Product features, authentication requirements, and the data model still need defining.

This handoff documents the environment and proposes the new stack. It does not create or deploy BERMUN.

## Verified existing environment

The following was inspected directly over SSH and through the connected Cloudflare account on 14 November 2026. Recheck availability and resource usage before deployment.

| Item | Observed value |
| --- | --- |
| SSH alias on this Mac | `knowledge-pi` |
| Pi LAN address | `192.168.178.113` |
| SSH user | `kiwi` |
| SSH identity on this Mac | `~/.ssh/knowledge_pi` |
| Hostname | `kiwi` |
| Architecture | `aarch64` / Docker `linux/arm64` |
| Operating system | Debian GNU/Linux 13 (trixie), reported version 13.7 |
| CPU | Four Cortex-A76 cores |
| Memory | Approximately 15 GiB total, 14 GiB available at inspection |
| Disk | Approximately 1.8 TiB total, 1.7 TiB free on the root NVMe filesystem |
| Docker Engine | `29.9.2` |
| Docker Compose | `v5.6.1`, invoked as `docker compose` |
| Docker access | `kiwi` belongs to the `docker` group |
| Existing Compose projects | `knowledge`, `shrimp`, `portainer` |
| BERMUN state | No `/opt/bermun` directory, Compose project, or named BERMUN tunnel observed; no exact DNS record for `bermun.kiwiapps.dev` |

The existing Mac SSH configuration is:

```sshconfig
Host knowledge-pi
    HostName 192.168.178.113
    User kiwi
    IdentityFile ~/.ssh/knowledge_pi
    IdentitiesOnly yes
```

Connect with:

```sh
ssh knowledge-pi
```

The alias identifies the shared Pi despite its Knowledge-specific name. It can be used from the new repository. The Mac needs a network route to the Pi's private address: use the home LAN or home VPN when away. The existing private SSH key stays on the Mac and must not be copied into the repository or this document.

### Existing workloads to preserve

| Workload | Server directory | Host binding / storage |
| --- | --- | --- |
| Knowledge | `/opt/knowledge` | Caddy at `127.0.0.1:8088`; PostgreSQL 18; volumes `knowledge_pgdata`, `knowledge_source_files`, `knowledge_caddy_data`, `knowledge_caddy_config` |
| Shrimp | `/opt/shrimp` | API at `127.0.0.1:3000`; PostgreSQL 16; volume `shrimp_pgdata` |
| Portainer | `/opt/portainer` | HTTPS at `192.168.178.113:9443`; volume `portainer_data` |

These stacks have separate Docker networks. BERMUN should have its own network and volumes too. Do not reuse their databases, passwords, tunnel tokens, or Compose project names. Do not stop or redeploy these applications as part of creating BERMUN. Avoid global Docker cleanup and any operation that deletes existing volumes.

## Proposed BERMUN architecture

```text
Browser
  https://bermun.kiwiapps.dev
       |
Cloudflare DNS + public HTTPS
       |
Dedicated Cloudflare Tunnel: bermun
       |
cloudflared container on the Pi
       |
http://bermun-caddy:80
       |-- /api and /api/* --> Express api:3000 --> PostgreSQL db:5432
       `-- other paths ----> compiled React static files
```

Serve the frontend and API from the same public origin. React should call relative URLs such as `/api/...`; it must never connect directly to PostgreSQL. No separate API hostname or production CORS setup is needed for this layout.

Suggested services:

| Compose service | Responsibility |
| --- | --- |
| `web` | Caddy image containing the compiled React frontend; reverse proxies the API; network alias `bermun-caddy` |
| `api` | Express production server; listens on `0.0.0.0:3000` inside Docker |
| `db` | Dedicated PostgreSQL instance and persistent `bermun_pgdata` volume |
| `migrate` | One-shot migration command using a database owner credential |
| `cloudflared` | Dedicated connector for the new remotely managed `bermun` tunnel |

Suggested starting choices: React + Vite + TypeScript, Express + TypeScript, Node.js 24, PostgreSQL 18, and Caddy 2. These are proposed project choices, not claims about the latest releases. Choose maintained package versions and pin dependencies in the new lockfile; record image versions or digests for reproducible releases. All images must support ARM64.

Build React during image creation and serve its output with Caddy. The Vite development server is for local development. Use a local Vite `/api` proxy to Express to retain relative API URLs during development.

Keep API and database ports unpublished. An optional local gateway binding is `127.0.0.1:8089:80`; port 8089 had no listening socket at inspection, but is not reserved. Recheck it before use. Internal ports 3000 and 5432 can be reused inside BERMUN's separate Docker network.

### Gateway configuration sketch

This is a proposed Caddyfile for the `web` image; `/srv` must contain the compiled React files.

```caddyfile
{
    admin off
    auto_https off
}

:80 {
    header -Server
    encode gzip

    @api path /api /api/*
    handle @api {
        reverse_proxy api:3000
    }

    handle {
        root * /srv
        try_files {path} /index.html
        file_server
    }
}
```

Mount the Express router at `/api`: the proxy preserves the prefix. API misses must return an API 404 rather than the React HTML page. The frontend fallback supports client-side routes opened directly. This follows [Caddy's documented SPA and API routing pattern](https://caddyserver.com/docs/caddyfile/patterns#single-page-apps-spas).

Public HTTPS terminates at Cloudflare; the final connector-to-Caddy hop uses HTTP within the private Docker network. If authentication or redirects are added, configure trusted proxies and the public HTTPS scheme across Cloudflare, Caddy, and Express deliberately so secure cookies and redirect URLs work. Do not blindly trust client-supplied forwarding headers.

## Domain and Cloudflare setup

| Item | Value |
| --- | --- |
| DNS zone | `kiwiapps.dev`, active in Cloudflare |
| Cloudflare zone ID | `de0a8275b90867cb5070fb20930e11ea` |
| Cloudflare account ID | `77445b7376ddd5ee82201aef8608c995` |
| Authoritative nameservers | `harlee.ns.cloudflare.com`, `walt.ns.cloudflare.com` |
| New tunnel name | `bermun` — proposed; not created |
| New tunnel ID | To be assigned when created |
| Published hostname | `bermun.kiwiapps.dev` |
| Published service | `http://bermun-caddy:80` |

The existing Knowledge documentation identifies Name.com as the registrar. DNS authority was verified as Cloudflare; registrar access was not checked. No registrar or nameserver change is needed to add this hostname.

Setup to perform in the new project:

1. Create a separate remotely managed Cloudflared tunnel named `bermun` in the existing Cloudflare account. The dashboard currently documents this under **Networking → Tunnels**.
2. Store its connector token privately on the Pi at `/opt/bermun/.secrets/cloudflared-token`. Mount it into the connector as a secret file and use `tunnel --no-autoupdate run --token-file /run/secrets/cloudflared_token`. Never put the token in Git, chat, logs, or command arguments.
3. Put the connector and `web` service on the BERMUN Compose network. Set `bermun-caddy` as an alias of `web` on that network.
4. Add a published application route with subdomain `bermun`, domain `kiwiapps.dev`, no path restriction, service type **HTTP**, and service URL **`bermun-caddy:80`**.
5. Let Cloudflare create the proxied DNS record. If creating it manually, use a proxied CNAME named `bermun` targeting `<BERMUN_TUNNEL_ID>.cfargotunnel.com` with automatic TTL.

The connector must use the Docker service alias, not `localhost`: inside the connector, `localhost` refers to the connector itself. No router port forwarding or public Pi IP is required. Leave the existing Knowledge and Shrimp tunnels and DNS records unchanged. See [Cloudflare Tunnel setup and application publishing](https://developers.cloudflare.com/tunnel/get-started/).

For reference only, the existing healthy tunnels were `knowledge` (`122e8f85-0262-4422-a3e4-47e5a04aae94`) and `shrimp-api` (`b2247961-552c-4014-8645-74f26f3f040c`). BERMUN needs a new tunnel and token.

## Suggested repository and server layout

```text
New BERMUN repository             Raspberry Pi
  apps/web/                        /opt/bermun/
  apps/api/                          releases/<release-id>/
  packages/                          current -> releases/<release-id>
  infra/                             previous -> releases/<previous-id>
    compose/compose.yaml             .env
    compose/tunnel.yaml               .secrets/
    caddy/Caddyfile                     db-owner-password
    postgres/                          db-app-password
    scripts/                           cloudflared-token
  docs/Deployment.md                 config/
  .env.example                       backups/
  .gitignore                         .deployment.lock
  package.json
  package-lock.json
```

Use Compose project name `bermun` explicitly. Use only `bermun_`-prefixed persistent volume names, including `bermun_pgdata`. With the proposed PostgreSQL 18 image, follow the existing deployment's mount at `/var/lib/postgresql`; check the selected image's documented data layout before implementation.

Use database name `bermun`, database owner/migration role `bermun_owner`, and runtime role `bermun_api`. Generate new credentials once and preserve them across releases. Keep `.secrets/` private, mount only the required files into each service, and exclude secrets and populated environment files from Git and source archives. Frontend build variables are public; database credentials and application secrets belong only on the backend.

Authentication has not been specified. Decide it in the new project; the Knowledge account system and AI-provider integrations are not BERMUN requirements. Any required session/signing secrets should be generated independently and retained across releases.

## Deployment workflow to implement

Reuse the operational approach of Knowledge, adapting it for BERMUN:

1. Archive only the new project's required source and lockfile on the Mac, excluding credentials, dependencies, and generated files.
2. Upload over SSH to `/opt/bermun`, verify a checksum, and extract into a timestamped release directory.
3. Record the source checksum, Git revision, and unique image tags. Build ARM64 frontend and backend images on the Pi; a registry is optional.
4. Serialize deployments with a BERMUN-specific filesystem lock. Create credentials and volumes only when absent.
5. Back up the existing BERMUN database before migrations. Run immutable, forward-compatible migrations as the owner role, then start Express using the limited runtime role.
6. Start the web service, API, database, and connector. Include operational database/API health checks and bounded log rotation. Proposed API endpoints are `/api/status` and `/api/ready`; readiness should verify database connectivity.
7. Update `current` after successful startup. Preserve the previous release and its image tags for application rollback.
8. Provide BERMUN-specific deploy, status, logs, backup, and rollback scripts. Keep the working directory, project name, environment files, and Compose overlays consistent in every operation.

Use PostgreSQL custom-format dumps and copy backups off the Pi. Also retain protected configuration/secrets backups and any future uploaded-file storage. Application rollback does not reverse migrations or restore data; plan database recovery separately. Never use `docker compose down --volumes` against a persistent deployment.

The scripts above do not exist for BERMUN yet. Creating `/opt/bermun` initially needs suitable privileges; routine deployments can follow the existing `kiwi`-owned application-directory pattern.

## Existing implementation references

On this Mac, the reference repository is `/Users/oskar/Desktop/Knowledge`:

- `docs/Backend-Deployment.md`: deployment, backups, rollback, and tunnel setup.
- `infra/scripts/deploy.sh` and `infra/scripts/apply-release.sh`: source upload and release application.
- `infra/scripts/compose-lib.sh`: consistent project and environment selection.
- `infra/scripts/configure-tunnel.sh` and `infra/scripts/activate-tunnel.sh`: hidden token input and secret-file installation.
- `infra/compose/compose.yaml` and `infra/compose/tunnel.yaml`: service isolation and connector configuration.
- `infra/caddy/Caddyfile`: existing gateway configuration; BERMUN also needs React static-file serving.

These scripts hardcode Knowledge paths, project names, variables, and source selections. Use them as references; do not run them to deploy BERMUN. Adapt every application-specific value in the new repository and review the resulting commands before execution. The Knowledge checkout contains unrelated local changes that must be preserved.

## Starting prompt for a new project

> Build a separate application named BERMUN using React, Express, and PostgreSQL. Use this handoff as deployment context. All services will run on my existing ARM64 Raspberry Pi and be published at https://bermun.kiwiapps.dev through a dedicated Cloudflare Tunnel. Use a separate repository, Compose project `bermun`, server directory `/opt/bermun`, database, roles, secrets, network, and persistent volumes. Serve the compiled React frontend and `/api` from one origin through Caddy. Start by defining the application features and data model with me, then implement the application and its deployment scripts. Preserve the existing Knowledge, Shrimp, and Portainer stacks. The handoff describes a proposed BERMUN setup; its directory, tunnel, DNS, and deployment scripts have not been created. Recheck the environment before deploying.

## Verification scope for this handoff

Read-only checks covered SSH access, host resources, Docker versions, running stacks, network/volume names, listening ports, DNS authority, exact BERMUN DNS records, existing tunnels, and Knowledge's published tunnel route. No application tests or manual application testing were performed. No server files, containers, DNS records, tunnel configuration, or credentials were changed.
