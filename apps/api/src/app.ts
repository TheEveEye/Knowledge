import { randomUUID } from "node:crypto";
import Fastify from "fastify";
import { sql } from "drizzle-orm";
import type { Config } from "./config.js";
import { createDatabase } from "./db/client.js";
import { bundledMigrations } from "./db/migrations.js";

const statusSchema = {
  type: "object",
  additionalProperties: false,
  required: ["status", "service", "version", "revision"],
  properties: {
    status: { type: "string", enum: ["ok"] },
    service: { type: "string" },
    version: { type: "string" },
    revision: { type: "string" },
  },
} as const;

export function createApp(config: Config) {
  const app = Fastify({
    bodyLimit: 1_048_576,
    requestTimeout: 30_000,
    connectionTimeout: 10_000,
    forceCloseConnections: "idle",
    genReqId: () => randomUUID(),
    requestIdHeader: false,
    logger: {
      level: config.logLevel,
      redact: ["req.headers.authorization", "req.headers.cookie", "res.headers.set-cookie"],
      serializers: {
        req(request) {
          return { method: request.method, url: request.url.split("?")[0] ?? "/" };
        },
      },
    },
  });
  const { db, pool } = createDatabase(config);
  let closing = false;

  // Idle pool failures are handled without logging connection strings or credentials.
  pool.on("error", () => app.log.error("Idle database connection failed"));
  app.addHook("preClose", async () => { closing = true; });
  app.addHook("onClose", async () => { await pool.end(); });
  app.addHook("onRequest", async (_request, reply) => {
    reply.header("Cache-Control", "no-store");
    reply.header("X-Content-Type-Options", "nosniff");
  });
  app.setErrorHandler((error, request, reply) => {
    const status = error instanceof Error && "statusCode" in error
      && typeof error.statusCode === "number" && error.statusCode >= 400 && error.statusCode < 500
      ? error.statusCode : 500;
    const code = error instanceof Error && "code" in error && typeof error.code === "string"
      ? error.code : "UNKNOWN";
    request.log.error({ code, statusCode: status }, "Request failed");
    return reply.code(status).send({ error: status === 500 ? "Internal server error" : "Invalid request" });
  });

  app.get("/api/status", { schema: { response: { 200: statusSchema } } }, async () => ({
    status: "ok", service: "knowledge-api", version: config.version, revision: config.revision,
  }));

  app.get("/api/ready", async (_request, reply) => {
    if (closing) return reply.code(503).send({ status: "unavailable" });
    try {
      const result = await db.execute<{ hash: string }>(sql`
        SELECT hash FROM drizzle.__drizzle_migrations
      `);
      const appliedHashes = new Set(result.rows.map((row) => row.hash));
      if (!bundledMigrations.every((migration) => appliedHashes.has(migration.hash))) {
        return reply.code(503).send({ status: "unavailable" });
      }
      return { status: "ready" };
    } catch {
      return reply.code(503).send({ status: "unavailable" });
    }
  });

  return app;
}
