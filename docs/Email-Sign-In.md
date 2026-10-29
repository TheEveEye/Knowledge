# Email accounts

Knowledge uses Better Auth email/password authentication. Creating an account requires a name, email, and password; email ownership must be verified before password sign-in succeeds. Email codes are used only for verification and password recovery. The retired `/api/auth/sign-in/email-otp` endpoint returns 404.

## Account flows

- **Create account:** submit name/email/password, then explicitly request an email-verification code. Enter the code; the iOS app then signs in automatically using the password entered during signup. The password is retained only in memory during this flow and discarded on completion or exit. Signup and verification endpoints do not themselves create sessions; automatic sign-in still requires the correct password. Duplicate signup responses are generic and never overwrite an existing password; use recovery for an existing account.
- **Sign in:** submit email/password. A successful response issues the existing signed native bearer header and browser cookie. Unverified users are directed to email verification.
- **Set or reset password:** request a recovery code, then submit that code and a new password. This also adds a credential identity to an existing email-code account, preserving the permanent user UUID. Recovery proves email ownership, marks the email verified, revokes all previous sessions, and requires password sign-in afterwards.
- Existing sessions remain valid until revoked or expired. No data or schema migration is needed: the existing accounts table already has a password-hash field. Never invent passwords or replace user identities during migration.

Passwords must be 15–128 characters, may contain spaces, and have no forced composition rules. Better Auth uses its built-in salted scrypt hashing. The app sends passwords only over the configured HTTPS origin and never persists them in Keychain, preferences, logs, or the library. It stores signed session credentials in the existing device-only Keychain service. Password fields use native password-manager content types.

## Delivery configuration

The existing Resend sending domain `auth.kiwiapps.dev` and private sending key are retained. Emails are sent through the official Resend Node SDK as purpose-specific HTML and plain text. The published `knowledge-sign-in-code` template is no longer used: verification and recovery now have different subjects and instructions. `EMAIL_TEMPLATE_ID` is obsolete and ignored; there is no new template setup required.

For a fresh deployment:

1. Add the sending domain to Resend, install its exact DNS records, and wait for verification. Keep verification records DNS-only and preserve unrelated DNS/mail records.
2. Create a Sending access key restricted to that domain. Disable open/click tracking for authentication emails. Keep the key out of chat and Git.
3. Run `./infra/scripts/configure-email.sh knowledge-pi` from the Mac repository and paste the key into its hidden prompt. The script installs `/opt/knowledge/.secrets/email-api-key` via SSH stdin and restarts the API with the email overlay. No email is sent on startup.

The default sender is `Knowledge <signin@auth.kiwiapps.dev>`. `EMAIL_FROM` and `EMAIL_DAILY_LIMIT` can be set in `/opt/knowledge/.env`. Keep the sending key in the protected configuration backup. Without delivery enabled, new registration and sending endpoints return 503; password sign-in for verified users remains available. Verification/reset submission can complete while delivery is disabled if a valid code has already been delivered.

## HTTP contract

| Endpoint | JSON body | Result |
| --- | --- | --- |
| `GET /api/auth/methods` | None | `emailPassword: true`, `emailOTP: false`, delivery availability, password bounds, code timing |
| `POST /api/auth/sign-up/email` | `{ email, name, password }` | Unverified account or generic duplicate response; no session |
| `POST /api/auth/sign-in/email` | `{ email, password }` | Verified user and session cookie/signed bearer header |
| `POST /api/auth/email-otp/send-verification-otp` | `{ email, type: "email-verification" }` | Generic success for unknown email; provider acceptance for an eligible account |
| `POST /api/auth/email-otp/verify-email` | `{ email, otp }` | Email verified; no session |
| `POST /api/auth/email-otp/request-password-reset` | `{ email }` | Generic success for unknown email; provider acceptance for an existing account |
| `POST /api/auth/email-otp/reset-password` | `{ email, otp, password }` | Password saved and old sessions revoked; no session |

POSTs require JSON, a body no larger than 2 KiB, and an explicit trusted Origin. Native requests use `https://knowledge.kiwiapps.dev`. Redirects and arbitrary callback URLs are not accepted by these dedicated routes. Plain-code retrieval, OTP login, email change, default reset links, and other unimplemented auth operations remain inaccessible.

Use the signed `set-auth-token` response header as the native bearer credential. The raw JSON/database session token is not accepted as an unsigned bearer token. Browser clients should use the HttpOnly cookie. Session renewal, sign-out, revocation, CSRF protections, and host-only cookie settings are unchanged.

## Limits and privacy

- Cryptographically random six-digit codes expire after five minutes, permit five attempts, and are consumed once. Verification and recovery use separate namespaces; their codes are not interchangeable. Stored codes use keyed HMAC hashes.
- Database-backed limits per IP/path: five sign-ins, five verification attempts, five reset submissions, three signups, and three code requests per minute. These are in addition to the default auth limiter.
- Before code generation, shared PostgreSQL delivery budgets enforce a 60-second recipient cooldown, five requests per recipient per hour, and 90 globally per UTC day. Recipient keys use HMACs. Rejected resends do not rotate a delivered code. Unknown-address requests also reserve a budget to avoid bypassing the limiter through account discovery.
- Accepted resends rotate codes. Resend retries retain the same code, content, and idempotency key, with at most three attempts, bounded backoff, and respect for Retry-After. Provider failures may consume the application budget.
- Provider acceptance logs contain only the email ID. Passwords, recipients, codes, auth bodies, headers, and raw provider errors are excluded from logs. Resend debug logging remains disabled. Successful recovery requests do not confirm whether an account exists; this does not guarantee identical response timing.

## iOS behavior and data ownership

A Knowledge account is required to enter the app. Session restoration completes before the library appears; failures offer retry or another account. Sign-out returns to the entry screen and pauses AI work. Password/code fields clear when the flow changes or the view closes. **Account → AI connections → ChatGPT** remains independent.

The library remains on this device. Sign-in does not claim, partition, upload, or transfer it. Account-scoped local storage and explicit ownership migration are still required before cloud sync. Account deletion, social sign-in, profile editing, and OpenAI API billing remain subsequent milestones.

References: [Better Auth email/password](https://better-auth.com/docs/authentication/email-password), [email verification](https://better-auth.com/docs/concepts/email), [email OTP verification and recovery](https://better-auth.com/docs/plugins/email-otp), [Resend sending API](https://resend.com/docs/api-reference/emails/send-email).
