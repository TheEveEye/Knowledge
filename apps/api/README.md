# Knowledge API

Fastify 5, TypeScript, Drizzle ORM, and PostgreSQL. Node.js 24 is the supported runtime; `.nvmrc` records that major version. Dependencies are locked in the repository-root `package-lock.json`.

## Operational routes

| Route | Success | Dependency |
| --- | --- | --- |
| `GET /api/status` | `200`, with service, version, and source revision | API process |
| `GET /api/ready` | `200`, `{"status":"ready"}` | Database reachable and every migration bundled with this release applied |

Readiness returns `503`, `{"status":"unavailable"}` if those conditions fail. Neither route exposes credentials, database errors, hostnames, or connection strings. Replies are not cached. There is no `/health` route.

These endpoints are production operations features. No test targets, fixtures, test-only probes, or harnesses are included. Follow the root [project instructions](../../AGENTS.md).

## Development

From the repository root, with Docker running:

```sh
npm run dev:up
```

The command generates private local database credentials if absent, builds the API, applies migrations, and starts PostgreSQL and Caddy. The local API is available through Caddy at `http://127.0.0.1:8088/api/status`. The development override publishes PostgreSQL at `127.0.0.1:5433` and the API directly at `127.0.0.1:3001`.

```sh
npm run dev:logs
npm run dev:down
```

Stopping the development stack retains its named database volume. Never add `--volumes` to a shutdown command for data you intend to retain.

For host-based development, install Node 24 and run `npm ci` at the repository root. With the development database running:

```sh
DB_PORT=5433 DB_PASSWORD_FILE="$PWD/.secrets/db-app-password" npm run dev
```

The host process listens on `127.0.0.1:3000`; its logging and database limits match the container. Use `npm run build` or `npm run typecheck` for compilation. These commands do not run tests.

## Database and migrations

- `src/db/schema.ts` declares Drizzle application schemas. The initial migration creates the `knowledge` schema; account and library tables are intentionally deferred until their data contracts are designed.
- `drizzle/` holds version-controlled SQL migrations, snapshots, and the migration journal. Generate new migrations with `npm run db:generate -- --name=descriptive_name` from the repository root, then review their SQL.
- The one-shot migration process uses the owner credential. An advisory lock serializes database migrations, and Drizzle applies pending changes transactionally and tracks them in its journal. Shipped migrations are immutable.
- The API connects as `knowledge_api`, a non-superuser role that cannot create roles or databases. It has access to application data and read-only access to the migration journal.
- Additional migrations can remain applied when an older compatible API image is restored. Readiness checks for this release's required migrations without requiring an exact match to the newest database release.
- Never use schema push, drop the database, or recreate its volume as a deployment shortcut. Production changes should remain compatible with the preceding API image during rollout.

The initial role bootstrap runs only on an empty PostgreSQL volume. Changing a credential file later does not rotate an existing database role's password; use an explicit coordinated credential rotation.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `HOST` | `127.0.0.1` | Listener; Compose uses `0.0.0.0` inside the container |
| `PORT` | `3000` | HTTP listener port |
| `LOG_LEVEL` | `info` | Structured JSON logging level |
| `APP_REVISION` | `development` | Release identifier returned by status |
| `DB_HOST` | `127.0.0.1` | PostgreSQL host |
| `DB_PORT` | `5432` | PostgreSQL port |
| `DB_NAME` | `knowledge` | PostgreSQL database |
| `DB_USER` | `knowledge_api` | Runtime role; migration service uses `knowledge_owner` |
| `DB_PASSWORD_FILE` | Required unless `DB_PASSWORD` is set | Mounted credential file |

Database connections remain inside the private Docker network in production. There are no public database or API container ports; Caddy is the gateway. Authentication and authorization for Knowledge accounts, the AI-provider connection, library sync, and background processing are later milestones. Only the operational routes are available in this release.

Request logging excludes query strings, headers, and bodies; error responses omit internal details. SIGTERM/SIGINT initiate graceful HTTP and database shutdown, with a bounded deadline.

The root dependency override updates Drizzle Kit's legacy esbuild helper to a patched esbuild release. Development dependencies, including Drizzle Kit, are removed from the runtime image.

See [backend deployment](../../docs/Backend-Deployment.md) for the Pi, release scripts, and Cloudflare setup.
