import { betterAuth } from "better-auth";
import { bearer } from "better-auth/plugins/bearer";
import { drizzleAdapter } from "@better-auth/drizzle-adapter";
import type { Config } from "../config.js";
import type { Database } from "../db/client.js";
import * as schema from "../db/schema.js";

export function createAuth(config: Config, db: Database) {
  return betterAuth({
    appName: "Knowledge",
    baseURL: config.auth.baseURL,
    basePath: "/api/auth",
    secret: config.auth.secret,
    trustedOrigins: config.auth.trustedOrigins,
    database: drizzleAdapter(db, { provider: "pg", schema, transaction: true }),
    emailAndPassword: { enabled: false },
    user: { changeEmail: { enabled: false }, deleteUser: { enabled: false } },
    account: {
      encryptOAuthTokens: true,
      storeStateStrategy: "database",
      accountLinking: {
        enabled: true,
        disableImplicitLinking: true,
        allowDifferentEmails: true,
        allowUnlinkingAll: false,
      },
    },
    session: {
      expiresIn: 60 * 60 * 24 * 7,
      updateAge: 60 * 60 * 24,
      freshAge: 60 * 5,
      cookieCache: { enabled: false },
    },
    rateLimit: { enabled: true, storage: "database", window: 60, max: 100 },
    advanced: {
      database: { generateId: "uuid" },
      useSecureCookies: config.auth.baseURL.startsWith("https:"),
      cookiePrefix: "knowledge",
      defaultCookieAttributes: { httpOnly: true, sameSite: "lax", path: "/" },
      crossSubDomainCookies: { enabled: false },
      trustedProxyHeaders: false,
      ipAddress: { ipAddressHeaders: ["x-knowledge-client-ip"] },
    },
    plugins: [bearer({ requireSignature: true })],
    // Never let upstream auth errors print headers, credentials, or verification values.
    logger: { disabled: true },
  });
}

export type Authentication = ReturnType<typeof createAuth>;
