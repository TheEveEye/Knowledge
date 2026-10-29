import { drizzle } from "drizzle-orm/node-postgres";
import pg from "pg";
import type { Config } from "../config.js";

export function createDatabase(config: Config, migration = false) {
  const pool = new pg.Pool({
    ...config.database,
    application_name: migration ? "knowledge-migrations" : "knowledge-api",
    max: migration ? 1 : 5,
    connectionTimeoutMillis: 3000,
    idleTimeoutMillis: 30_000,
    statement_timeout: migration ? 30_000 : 2000,
    query_timeout: migration ? 30_000 : 2500,
  });
  return { pool, db: drizzle(pool) };
}
