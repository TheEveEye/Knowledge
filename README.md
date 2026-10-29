# Knowledge

Knowledge turns study notes into source-grounded concepts, facts, and explained connections, with Recall practice built from the saved material.

This repository contains the Knowledge applications and shared documentation. It currently includes the iOS app and the API foundation. The web and Android applications will be added separately.

## Repository layout

| Path | Contents |
| --- | --- |
| `apps/ios/` | iOS app, Xcode project, app configuration, and detailed iOS documentation |
| `apps/api/` | Fastify API, Drizzle migrations, and backend documentation |
| `infra/` | Docker Compose, Caddy, PostgreSQL bootstrap, and deployment scripts |
| `docs/` | Shared Recall design and grading contracts |
| `AGENTS.md` | Project-wide instructions for AI development |

Future applications will use `apps/web/` and `apps/android/`. Shared API contracts will live in `packages/contracts/` when client-facing endpoints are implemented.

## Backend

The Node.js 24 backend exposes `/api/status` and `/api/ready`. From the repository root, `npm run dev:up` builds and starts the local Docker stack. See the [API README](apps/api/README.md) and [Pi deployment and Cloudflare setup](docs/Backend-Deployment.md).

## Open the iOS app

From the repository root:

```sh
open apps/ios/Knowledge.xcodeproj
```

Use Xcode 27 and the shared **Knowledge** scheme. See the [iOS README](apps/ios/README.md) for app behavior, setup, and build instructions.

## Shared documentation

- [Recall question system](docs/Recall-Question-System.md)
- [Recall grading instructions](docs/Recall-Grading-Instructions.md)

## Development policy

Follow [AGENTS.md](AGENTS.md) throughout the repository. Do not add tests or test infrastructure. Do not run automated or manual tests unless explicitly requested by the user.
