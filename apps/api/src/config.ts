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
    version: "0.1.0",
    database: {
      host: process.env.DB_HOST ?? "127.0.0.1",
      port: integer("DB_PORT", 5432, 65535),
      database: process.env.DB_NAME ?? "knowledge",
      user: process.env.DB_USER ?? "knowledge_api",
      password: databasePassword(),
    },
  };
}

export type Config = ReturnType<typeof loadConfig>;
