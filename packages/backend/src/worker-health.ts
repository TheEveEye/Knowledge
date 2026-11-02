import { desc } from "drizzle-orm";
import { connectDatabase } from "./database.js";
import { workerHeartbeats } from "./schema.js";
const { db, pool } = connectDatabase();
try {
  const row = (await db.select().from(workerHeartbeats).orderBy(desc(workerHeartbeats.updatedAt)).limit(1))[0];
  if (!row || Date.now() - row.updatedAt.getTime() > 45_000 || row.revision !== (process.env.APP_REVISION ?? "development")) process.exitCode = 1;
} catch { process.exitCode = 1; }
finally { await pool.end(); }
