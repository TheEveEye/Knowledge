# Knowledge

Knowledge turns study notes into source-grounded concepts, facts, and explained connections, with Recall practice built from the saved material.

This repository contains the Knowledge applications and shared documentation. The iOS app is currently implemented. The API, web app, and Android app will be added as separate applications in this repository.

## Repository layout

| Path | Contents |
| --- | --- |
| `apps/ios/` | iOS app, Xcode project, app configuration, and detailed iOS documentation |
| `docs/` | Shared Recall design and grading contracts |
| `AGENTS.md` | Project-wide instructions for AI development |

Future components will use `apps/api/`, `apps/web/`, and `apps/android/`. Shared API contracts will live in `packages/contracts/`, and deployment configuration and scripts will live in `infra/`. These directories will be introduced with their implementations.

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
