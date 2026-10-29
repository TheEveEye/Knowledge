# Knowledge account foundation

Knowledge owns each user's identity. A permanent `knowledge.users.id` UUID will own library data, sync state, purchases, and AI usage. Email/password is the current login method. Apple, Google, and other identity providers are deferred and can later become additional ways to sign in to that same user. AI-provider access is a separate permission and never determines ownership of application data.

## Implemented scope

Better Auth 1.7.14 runs inside Fastify at `/api/auth/`, using the Drizzle PostgreSQL adapter and the runtime `knowledge_api` database role. Migration `0001_account_foundation` adds:

| Table | Purpose |
| --- | --- |
| `knowledge.users` | Permanent user UUID, profile, verified email status, timestamps |
| `knowledge.accounts` | Credential password hashes, linked provider identity, and future provider credentials; unique provider/account pair |
| `knowledge.sessions` | Revocable sessions with expiry, user reference, and device metadata |
| `knowledge.verifications` | Expiring verification and OAuth transaction records |
| `knowledge.auth_rate_limits` | Shared authentication request counters |

The adapter's model names (`user`, `account`, `session`, `verification`, `rateLimit`) map to these Drizzle tables. PostgreSQL generates UUID defaults, including for adapter-created verification and rate-limit records. Foreign keys cascade sessions and linked identities when a user is deleted. Only the migration owner can change the schema; existing default grants give the API data access.

Email/password registration and sign-in are implemented. New accounts must verify their email before signing in. Email codes are restricted to email verification and password recovery; passwordless sign-in is disabled. Existing email-code accounts keep their UUID and use password recovery to add a password. No database migration or forced session invalidation is required. There are no seeded users or developer login bypasses. Social sign-in, account deletion, and identity linking endpoints remain disabled. The iOS app separates Knowledge sessions from the optional ChatGPT connection; its library remains device-local pending explicit migration. See [email sign-in setup](Email-Sign-In.md). `/api/me` returns 401 to unauthenticated clients.

## HTTP contract

| Endpoint | Method | Behavior |
| --- | --- | --- |
| `/api/me` | GET | Current Knowledge profile, or 401 `{"error":"Unauthorized"}` |
| `/api/auth/methods` | GET | Available login methods, password policy, and verification-code timing |
| `/api/auth/sign-up/email` | POST | Create an unverified email/password account; no session |
| `/api/auth/sign-in/email` | POST | Authenticate with email/password; verified email required |
| `/api/auth/email-otp/send-verification-otp` | POST | Send an email-verification code when delivery is enabled |
| `/api/auth/email-otp/verify-email` | POST | Verify ownership; no automatic session |
| `/api/auth/email-otp/request-password-reset` | POST | Request a recovery code; generic success for unknown addresses |
| `/api/auth/email-otp/reset-password` | POST | Consume recovery code, set a password, and revoke previous sessions |
| `/api/auth/get-session` | GET | Better Auth session contract; no active session returns its standard null response |
| `/api/auth/list-sessions` | GET | List the authenticated user's active sessions |
| `/api/auth/sign-out` | POST | End the current session and clear its cookie |
| `/api/auth/revoke-session` | POST | Revoke an owned session using Better Auth's `token` body field |
| `/api/auth/revoke-sessions` | POST | Revoke all of the authenticated user's sessions |
| `/api/auth/revoke-other-sessions` | POST | Revoke other sessions while retaining the current session |

The `/api/auth/*` bridge explicitly allows session methods and paths; dedicated email routes validate their bodies and require a trusted Origin. Adding a provider or account-management feature requires extending those routes alongside its implementation. Requests use the configured public origin, preserve separate `Set-Cookie` headers, and forward session-renewal headers. Session request bodies are limited to 16 KiB and email requests to 2 KiB. Responses use `Cache-Control: no-store`. Status and readiness remain public.

`/api/me` returns only `{ user: { id, name, email, emailVerified, image, createdAt } }`. The ID is a UUID, image is nullable, and creation time is an ISO timestamp. Tokens, provider credentials, IP addresses, and device metadata are excluded. The `/api/auth/` endpoints retain Better Auth's client contracts, including session tokens needed for its session-management operations; clients must treat those responses as credentials.

Future application routes must resolve their Knowledge session on the server, require verified email where appropriate, and filter every data access by that authenticated user's UUID. Never authorize requests using a submitted user ID, email, AI-provider token, or decoded but unverified identity claim.

## Sessions and credentials

- Sessions expire after seven days and renew after one day of use. Sensitive account actions will require a session created within five minutes. Cookie session caching is disabled so revocations take effect on the next database-backed check.
- Browser sessions use host-only, HttpOnly, SameSite=Lax cookies. HTTPS origins require Secure cookies. Cookie and CSRF protections stay enabled; no credentialed wildcard CORS is configured.
- Native clients can use the signed bearer token returned in `set-auth-token`, including its signature and original encoding. Raw unsigned database session tokens are rejected as bearer credentials. Store credentials in iOS Keychain or Android storage protected by Keystore. Web clients should use cookies rather than JavaScript-accessible persistent token storage.
- Future provider access and refresh tokens must use supported encryption when provider integration is implemented. Passwords use Better Auth’s built-in salted scrypt hashing. Password creation/reset requires 15–128 characters with no forced composition rules. Email codes use keyed hashes. Session identifiers and some other verification records are stored in the database in their library-defined form; protect database access and backups as credentials.
- Account linking is disabled. When social sign-in is implemented, add explicit linking with recent Knowledge authentication and proof of the provider identity. Support different emails, including Apple relay addresses, preserve the permanent user UUID, and prevent removal of the last login method. Never merge existing users solely on matching emails.
- Session endpoints are limited to 100 requests per minute per client IP and path, using PostgreSQL storage. Email endpoints have stricter limits and dedicated delivery budgets described in the email setup guide. `/api/me` uses the internal session API; Better Auth's HTTP rate limiter does not apply to that internal call.
- The bridge overwrites `x-knowledge-client-ip`. In the Cloudflare deployment it derives that value from a valid, single `CF-Connecting-IP`; development uses the socket address. Production API ports must remain private and reachable only through the controlled proxy path. Never enable Cloudflare header trust on a directly public API.
- Query strings, headers, and bodies remain excluded from request logging. Better Auth's logger is disabled to prevent upstream exceptions from printing credentials; Fastify records sanitized failures.

## Configuration and deployment

`AUTH_SECRET_FILE` supplies a private secret file; `AUTH_SECRET` is supported for host development. The value must have at least 32 characters. `init-secrets.sh` generates a random 32-byte hex secret once as `.secrets/auth-secret`; the API alone receives its read-only mount. PostgreSQL and the migrator do not receive it.

`AUTH_BASE_URL` is an explicit origin without a path, credentials, query, or fragment. Production defaults to `https://knowledge.kiwiapps.dev`. HTTP is permitted only for loopback development. `AUTH_TRUSTED_ORIGINS` accepts a comma-separated list of exact HTTPS origins, with the same loopback exception. No wildcard patterns are accepted. This setting governs authentication trust; it does not enable browser CORS or register native callback schemes.

`AUTH_TRUST_CLOUDFLARE=true` is the production Compose default. The development override sets it to false and selects `http://127.0.0.1:8088` as the origin. A directly running host process should use `http://127.0.0.1:3000`.

The standard deployment generates the secret if absent, backs up the database, applies the additive migration, and waits for the existing production readiness check. The previous API remains compatible with these added tables. Restoring an older API image does not remove accounts or roll back the database.

Keep `auth-secret` in the protected configuration backup together with the database passwords and tunnel token. Replacing it invalidates signed sessions and affects encrypted provider credentials; rotate it with an explicit migration plan rather than deleting the file. Release archives and Git must never include these files.

## Next implementation steps

1. Email delivery is configured with the verified Resend domain and a private sending key. Existing email-code users select Reset password before using password sign-in.
2. Implement account deletion before releasing account creation to App Store users. Apple/Google OAuth is deferred: add provider configuration, token verification, native/web client integration, and explicit identity linking together when that work resumes. No provider SDKs, credentials, entitlements, or social-login endpoints are configured currently.
3. Migrate the existing local library through explicit import into the selected Knowledge account. Partition local data and pending operations by user UUID before enabling account switching and cloud sync.
4. Introduce server-held OpenAI API credentials, per-user allowances, and usage accounting independently of login methods. A ChatGPT plan connection remains an optional AI connection if retained.

References: [Fastify integration](https://better-auth.com/docs/integrations/fastify), [Drizzle adapter](https://better-auth.com/docs/adapters/drizzle), [sessions](https://better-auth.com/docs/concepts/session-management), [account linking](https://better-auth.com/docs/concepts/users-accounts), [bearer tokens](https://better-auth.com/docs/plugins/bearer), [rate limits](https://better-auth.com/docs/concepts/rate-limit).
