import { migrate } from "drizzle-orm/node-postgres/migrator";
import { loadDatabaseConfig } from "../config.js";
import { createDatabase } from "./client.js";
import { migrationsFolder } from "./migrations.js";

const { pool } = createDatabase({ database: loadDatabaseConfig() }, true);
try {
  // One session owns the lock until migration and connection shutdown finish.
  const client = await pool.connect();
  try {
    await client.query("SELECT pg_advisory_lock(724611092)");
    // Reuse the locked session, so concurrent deploys cannot interleave migrations.
    const { drizzle } = await import("drizzle-orm/node-postgres");
    await migrate(drizzle(client), { migrationsFolder });
  } finally {
    client.release();
  }
  console.log(JSON.stringify({ level: "info", message: "Database migrations applied" }));
} catch {
  console.error(JSON.stringify({ level: "error", message: "Database migration failed" }));
  process.exitCode = 1;
} finally {
  await pool.end();
}
