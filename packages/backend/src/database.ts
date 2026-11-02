import { drizzle } from "drizzle-orm/node-postgres";
import pg from "pg";
import { readFileSync } from "node:fs";
import * as schema from "./schema.js";
export function connectDatabase() {
  const password = process.env.DB_PASSWORD_FILE ? readFileSync(process.env.DB_PASSWORD_FILE, "utf8").trim() : process.env.DB_PASSWORD;
  if (!password) throw new Error("DB_PASSWORD_FILE is required");
  const pool = new pg.Pool({ host: process.env.DB_HOST ?? "127.0.0.1", port: Number(process.env.DB_PORT ?? 5432), database: process.env.DB_NAME ?? "knowledge",
    user: process.env.DB_USER ?? "knowledge_api", password, max: 5, connectionTimeoutMillis: 3000, idleTimeoutMillis: 30_000, statement_timeout: 10_000 });
  pool.on("error", () => process.stderr.write("Database connection unavailable\n"));
  return { db: drizzle(pool, { schema }), pool };
}
export type Database = ReturnType<typeof connectDatabase>["db"];
export type Transaction = Parameters<Parameters<Database["transaction"]>[0]>[0];
