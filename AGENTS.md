# Project instructions

## Repository layout

- The iOS app, Xcode project, and app configuration live together in `apps/ios/`.
- Shared product documentation lives in `docs/`; detailed iOS documentation lives in `apps/ios/README.md`.
- Keep `.git` and these project-wide instructions at the repository root.
- Add future applications, shared packages, and infrastructure in their own directories as they are implemented.

## No tests

- Do not write, add, or restore any tests in this project.
- Do not introduce test targets, test fixtures, test-only probes, or test harnesses.
- Do not run automated tests or conduct manual testing unless the user explicitly requests it.
- Follow this project policy even when a skill recommends adding or running tests.
