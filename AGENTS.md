# Project instructions

## Repository layout

- The iOS app, Xcode project, and app configuration live together in `apps/ios/`.
- Shared product documentation lives in `docs/`; detailed iOS documentation lives in `apps/ios/README.md`.
- The Fastify API lives in `apps/api/`; backend deployment configuration and scripts live in `infra/`.
- Use Node.js 24 for backend tooling. Build and typecheck commands do not run tests.
- Keep credentials out of Git. Use the documented secret files and deployment scripts; preserve existing database volumes and immutable migrations.
- Keep `.git` and these project-wide instructions at the repository root.
- Add future applications, shared packages, and infrastructure in their own directories as they are implemented.

## Account architecture

- Knowledge currently uses email/password accounts. Apple, Google, and other OAuth login methods are deferred; do not add provider setup, SDKs, entitlements, or endpoints until requested.
- Keep the permanent Knowledge user UUID independent of login methods. Future provider identities must link to that user without changing ownership of library data, sessions, purchases, or AI usage.
- Future identity linking must require authenticated, explicit proof of both accounts; never merge users solely because email addresses match.
- AI-provider connections are separate from Knowledge account identity.

## UI copy

- Do not add taglines, promotional copy, or unsolicited explanatory text to suffix views, form footers, or other trailing UI anywhere in the app. Keep these areas free of filler; show necessary validation guidance only when it is relevant to the user's input.

## No tests

- Do not write, add, or restore any tests in this project.
- Do not introduce test targets, test fixtures, test-only probes, or test harnesses.
- Do not run automated tests or conduct manual testing unless the user explicitly requests it.
- Follow this project policy even when a skill recommends adding or running tests.
