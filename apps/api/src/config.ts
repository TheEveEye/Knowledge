import { readFileSync } from "node:fs";

function integer(name: string, fallback: number, maximum: number): number {
  const raw = process.env[name];
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isInteger(value) || value < 1 || value > maximum) {
    throw new Error(`Invalid ${name}`);
  }
  return value;
}

function databasePassword(): string {
  const filename = process.env.DB_PASSWORD_FILE;
  const password = filename
    ? readFileSync(filename, "utf8").trim()
    : process.env.DB_PASSWORD;
  if (!password) throw new Error("DB_PASSWORD_FILE or DB_PASSWORD is required");
  return password;
}

export function loadDatabaseConfig() {
  return {
    host: process.env.DB_HOST ?? "127.0.0.1",
    port: integer("DB_PORT", 5432, 65535),
    database: process.env.DB_NAME ?? "knowledge",
    user: process.env.DB_USER ?? "knowledge_api",
    password: databasePassword(),
  };
}

function origin(value: string, name: string): string {
  const url = new URL(value);
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(url.protocol === "http:" && loopback))
    || url.hostname.includes("*") || url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
    throw new Error(`Invalid ${name}: use an HTTPS origin (HTTP is allowed only on loopback)`);
  }
  return url.origin;
}

function authenticationConfig() {
  const filename = process.env.AUTH_SECRET_FILE;
  const secret = filename ? readFileSync(filename, "utf8").trim() : process.env.AUTH_SECRET;
  if (!secret || secret.length < 32) throw new Error("AUTH_SECRET_FILE or AUTH_SECRET must supply at least 32 characters");
  const baseURL = origin(process.env.AUTH_BASE_URL ?? "https://knowledge.kiwiapps.dev", "AUTH_BASE_URL");
  const trustedOrigins = [baseURL, ...(process.env.AUTH_TRUSTED_ORIGINS ?? "")
    .split(",").map((value) => value.trim()).filter(Boolean)
    .map((value) => origin(value, "AUTH_TRUSTED_ORIGINS"))];
  const trustCloudflare = process.env.AUTH_TRUST_CLOUDFLARE ?? "false";
  if (!["true", "false"].includes(trustCloudflare)) throw new Error("Invalid AUTH_TRUST_CLOUDFLARE");
  return { secret, baseURL, trustedOrigins: [...new Set(trustedOrigins)], trustCloudflare: trustCloudflare === "true" };
}

function emailConfig() {
  const enabled = process.env.EMAIL_AUTH_ENABLED ?? "false";
  if (!["true", "false"].includes(enabled)) throw new Error("Invalid EMAIL_AUTH_ENABLED");
  const from = process.env.EMAIL_FROM ?? "signin@auth.kiwiapps.dev";
  if (!/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(from)) throw new Error("Invalid EMAIL_FROM");
  const filename = process.env.EMAIL_API_KEY_FILE;
  const apiKey = enabled === "true"
    ? (filename ? readFileSync(filename, "utf8").trim() : process.env.EMAIL_API_KEY)
    : undefined;
  if (enabled === "true" && (!apiKey || !/^re_[A-Za-z0-9_-]+$/.test(apiKey))) throw new Error("A Resend EMAIL_API_KEY_FILE or EMAIL_API_KEY is required");
  if (process.env.RESEND_DEBUG === "true") throw new Error("RESEND_DEBUG must remain disabled to protect email credentials and recipients");
  return { enabled: enabled === "true", from, apiKey, dailyLimit: integer("EMAIL_DAILY_LIMIT", 90, 100_000) };
}

export function loadConfig() {
  const logLevel = process.env.LOG_LEVEL ?? "info";
  if (!["fatal", "error", "warn", "info", "debug", "trace", "silent"].includes(logLevel)) {
    throw new Error("Invalid LOG_LEVEL");
  }
  return {
    host: process.env.HOST ?? "127.0.0.1",
    port: integer("PORT", 3000, 65535),
    logLevel,
    revision: process.env.APP_REVISION ?? "development",
    version: "0.4.0",
    database: loadDatabaseConfig(),
    auth: authenticationConfig(),
    email: emailConfig(),
  };
}

export type Config = ReturnType<typeof loadConfig>;
