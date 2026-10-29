import { betterAuth } from "better-auth";
import { bearer } from "better-auth/plugins/bearer";
import { emailOTP } from "better-auth/plugins/email-otp";
import { createHmac, randomInt } from "node:crypto";
import { APIError, createAuthMiddleware } from "better-auth/api";
import { drizzleAdapter } from "@better-auth/drizzle-adapter";
import type { Config } from "../config.js";
import type { Database } from "../db/client.js";
import * as schema from "../db/schema.js";
import { EmailLimitError, reserveEmailDelivery, sendAccountCode } from "./email.js";

export function createAuth(config: Config, db: Database, onEmailSent?: (id: string) => void) {
  return betterAuth({
    appName: "Knowledge",
    baseURL: config.auth.baseURL,
    basePath: "/api/auth",
    secret: config.auth.secret,
    trustedOrigins: config.auth.trustedOrigins,
    hooks: { before: createAuthMiddleware(async (ctx) => {
      if (!["/email-otp/send-verification-otp", "/email-otp/request-password-reset"].includes(ctx.path)) return;
      if (!config.email.enabled) throw new APIError("SERVICE_UNAVAILABLE", { code: "SIGN_IN_UNAVAILABLE", message: "Account email delivery is unavailable." });
      if (typeof ctx.body?.email !== "string"
        || (ctx.path === "/email-otp/send-verification-otp" && ctx.body.type !== "email-verification")) throw new APIError("BAD_REQUEST");
      // HTTP IP limiting runs before this hook; reserve before OTP generation so
      // rejected resends cannot invalidate a code already delivered to the user.
      try { await reserveEmailDelivery(db, config, ctx.body.email.toLowerCase()); }
      catch (error) {
        if (error instanceof EmailLimitError) throw new APIError("TOO_MANY_REQUESTS", {
          code: "RATE_LIMITED", message: "Please wait before requesting another code.",
        }, { "Retry-After": String(error.retryAfter) });
        throw error;
      }
    }) },
    database: drizzleAdapter(db, { provider: "pg", schema, transaction: true }),
    emailAndPassword: {
      enabled: true, requireEmailVerification: true, autoSignIn: false,
      minPasswordLength: 15, maxPasswordLength: 128,
      revokeSessionsOnPasswordReset: true,
    },
    // Clients explicitly request a code after signup, so all sends pass through
    // the shared delivery budget before generating or rotating an OTP.
    emailVerification: { sendOnSignUp: false, sendOnSignIn: false, autoSignInAfterVerification: false },
    user: { changeEmail: { enabled: false }, deleteUser: { enabled: false } },
    // Knowledge currently supports email/password only. Provider integration and
    // explicit account linking will be added together when social sign-in ships.
    account: { accountLinking: { enabled: false, disableImplicitLinking: true } },
    session: {
      expiresIn: 60 * 60 * 24 * 7,
      updateAge: 60 * 60 * 24,
      freshAge: 60 * 5,
      cookieCache: { enabled: false },
    },
    rateLimit: {
      enabled: true, storage: "database", window: 60, max: 100,
      customRules: {
        "/email-otp/send-verification-otp": { window: 60, max: 3 },
        "/sign-in/email": { window: 60, max: 5 },
        "/sign-up/email": { window: 60, max: 3 },
        "/email-otp/verify-email": { window: 60, max: 5 },
        "/email-otp/request-password-reset": { window: 60, max: 3 },
        "/email-otp/reset-password": { window: 60, max: 5 },
      },
    },
    advanced: {
      database: { generateId: "uuid" },
      useSecureCookies: config.auth.baseURL.startsWith("https:"),
      cookiePrefix: "knowledge",
      defaultCookieAttributes: { httpOnly: true, sameSite: "lax", path: "/" },
      crossSubDomainCookies: { enabled: false },
      trustedProxyHeaders: false,
      ipAddress: { ipAddressHeaders: ["x-knowledge-client-ip"] },
    },
    plugins: [bearer({ requireSignature: true }), emailOTP({
      disableSignUp: true,
      otpLength: 6, expiresIn: 300, allowedAttempts: 5, resendStrategy: "rotate",
      generateOTP: () => randomInt(0, 1_000_000).toString().padStart(6, "0"),
      storeOTP: { hash: async (otp) => createHmac("sha256", config.auth.secret).update(`email-otp:${otp}`).digest("hex") },
      sendVerificationOTP: async ({ email, otp, type }) => {
        if (type !== "email-verification" && type !== "forget-password") throw new Error("Unsupported email operation");
        const id = await sendAccountCode(config, email, otp, type);
        onEmailSent?.(id);
      },
    })],
    // Never let upstream auth errors print headers, credentials, or verification values.
    logger: { disabled: true },
  });
}

export type Authentication = ReturnType<typeof createAuth>;
