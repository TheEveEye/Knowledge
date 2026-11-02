import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { and, asc, desc, eq, gt, sql } from "drizzle-orm";
import { AIService, ChatService, DomainError, FileStore, ImportService, JobQueue, LibraryService, RecallService, aiRequests, draftChangeSchema, entityKinds, events, expected, importDTO, imports, invalidate, jobDTO, jobs, mutation, mutationSchema, ownedSubject, pendingDecisions, preferences, requireValue, selectionSchema, SourceService, uuid, workerHeartbeats } from "@knowledge/backend";
import type { Database } from "@knowledge/backend";
import type pg from "pg";
import type { JSONObject } from "@knowledge/contracts";
import type { Authentication } from "../auth/auth.js";
import { authHeaders, forwardHeaders } from "../auth/routes.js";
import type { Config } from "../config.js";

const pageSchema = z.object({ cursor: z.string().optional(), limit: z.coerce.number().int().min(1).max(100).default(50) });
const createSchema = z.strictObject({ operationID: uuid, name: z.string().min(1).max(160) });
const object = z.record(z.string().max(120), z.json());
// Recover conversations already containing a blank assistant reply from older builds.
// Empty user messages remain invalid; empty assistant placeholders are never model input.
const chatMessages = z.array(z.strictObject({ role: z.enum(["user", "assistant"]), content: z.string().max(20_000) })).min(1).max(40)
  .refine(messages => messages.some(m => m.role === "user") && messages.every(m => m.role !== "user" || m.content.trim().length > 0))
  .transform(messages => messages.filter(m => m.content.trim().length > 0));
const parseID = (r: FastifyRequest, key: string) => uuid.parse((r.params as Record<string, unknown>)[key]);
const userID = (r: FastifyRequest) => requireValue((r as FastifyRequest & { knowledgeUserID: string | null }).knowledgeUserID);
const sourceDTO = (s: Awaited<ReturnType<SourceService["get"]>>) => ({ id: s.id, subjectID: s.subjectId, title: s.title, kind: s.kind, digest: s.digest, byteCount: s.byteCount, status: s.status, error: s.error, archived: s.archived, createdAt: s.createdAt.toISOString() });
function stream(reply: FastifyReply) {
  const headers: Record<string, string | number | string[]> = {};
  for (const [key, value] of Object.entries(reply.getHeaders())) if (value !== undefined) headers[key] = value;
  reply.hijack(); reply.raw.writeHead(200, { ...headers, "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive", "X-Accel-Buffering": "no" });
  reply.raw.flushHeaders();
  const heartbeat = setInterval(() => { if (!reply.raw.destroyed && !reply.raw.writableEnded) reply.raw.write(": heartbeat\n\n"); }, 5000);
  reply.raw.once("close", () => clearInterval(heartbeat));
  return (event: string, data: unknown) => { if (!reply.raw.destroyed && !reply.raw.writableEnded) reply.raw.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); };
}
export function registerLibraryRoutes(parent: FastifyInstance, db: Database, pool: pg.Pool, auth: Authentication, config: Config) {
  const files = new FileStore(), library = new LibraryService(db), queue = new JobQueue(db), ai = new AIService(db, pool), sources = new SourceService(db, files), importer = new ImportService(db, ai, queue), recall = new RecallService(db, ai, queue);
  const shutdown = new AbortController(); parent.addHook("preClose", async () => { shutdown.abort(); });
  parent.register(async app => {
    app.decorateRequest("knowledgeUserID", null);
    app.setErrorHandler((error, request, reply) => {
      if (error instanceof DomainError) return reply.code(error.statusCode).send({ code: error.code, message: error.message, requestID: request.id });
      if (error instanceof Error && "code" in error && error.code === "FST_ERR_CTP_BODY_TOO_LARGE") return reply.code(413).send({ code: "SOURCE_TOO_LARGE", message: "Choose a file of at most 25 MiB.", requestID: request.id });
      if (error instanceof z.ZodError) return reply.code(400).send({ code: "INVALID_REQUEST", message: "The request did not match the required format.", requestID: request.id });
      request.log.error({ requestID: request.id, code: "APPLICATION_FAILURE" }, "Application request failed");
      return reply.code(500).send({ code: "INTERNAL_ERROR", message: "The operation could not be completed.", requestID: request.id });
    });
    app.addHook("onRequest", async (request, reply) => {
      const session = await auth.api.getSession({ headers: authHeaders(request, config), returnHeaders: true }); forwardHeaders(session.headers, reply);
      if (!session.response?.user.emailVerified) throw new DomainError("UNAUTHORIZED", "Sign in to Knowledge to continue.", 401);
      (request as FastifyRequest & { knowledgeUserID: string }).knowledgeUserID = session.response.user.id;
      if (!["GET", "HEAD"].includes(request.method) && (typeof request.headers.origin !== "string" || !config.auth.trustedOrigins.includes(request.headers.origin))) throw new DomainError("INVALID_ORIGIN", "This request origin is not allowed.", 403);
    });
    app.addContentTypeParser("application/octet-stream", { parseAs: "buffer", bodyLimit: 25 * 1024 * 1024 }, (_request, body, done) => done(null, body));
    app.get("/subjects", async r => { const q = pageSchema.parse(r.query); return library.list(userID(r), q.cursor ? uuid.parse(q.cursor) : undefined, q.limit); });
    app.post("/subjects", async r => { const b = createSchema.parse(r.body); return library.create(userID(r), b.operationID, b.name); });
    app.get("/subjects/:subjectID", r => library.subject(userID(r), parseID(r, "subjectID")));
    app.patch("/subjects/:subjectID", r => { const b = mutationSchema.extend({ name: z.string().min(1).max(160) }).parse(r.body); return library.rename(userID(r), parseID(r, "subjectID"), b.operationID, b.expectedVersion, b.name); });
    app.delete("/subjects/:subjectID", r => { const b = mutationSchema.parse(r.body); return library.delete(userID(r), parseID(r, "subjectID"), b.operationID, b.expectedVersion); });
    app.get("/subjects/:subjectID/entries", r => { const q = pageSchema.extend({ kind: z.enum(entityKinds).optional(), search: z.string().max(200).optional() }).parse(r.query); return library.entries(userID(r), parseID(r, "subjectID"), q.kind, q.cursor ? uuid.parse(q.cursor) : undefined, q.limit, q.search); });
    app.patch("/subjects/:subjectID/entries/:entityID", r => { const b = mutationSchema.extend({ fields: object }).parse(r.body); return library.edit(userID(r), parseID(r, "subjectID"), parseID(r, "entityID"), b.operationID, b.expectedVersion, b.fields as JSONObject); });
    app.post("/subjects/:subjectID/entries/:entityID/suggestions/:sourceID/undo", r => { const b = mutationSchema.extend({ wordingIndex: z.number().int().nonnegative().nullable().default(null) }).parse(r.body); return library.undoSuggestion(userID(r), parseID(r, "subjectID"), parseID(r, "entityID"), parseID(r, "sourceID"), b.operationID, b.expectedVersion, b.wordingIndex); });
    app.get("/subjects/:subjectID/entries/:entityID", r => library.entry(userID(r), parseID(r, "subjectID"), parseID(r, "entityID")));
    app.put("/subjects/:subjectID/placements/:conceptID", r => { const b = mutationSchema.extend({ topicID: uuid.nullable(), locked: z.boolean() }).parse(r.body); return library.move(userID(r), parseID(r, "subjectID"), parseID(r, "conceptID"), b.operationID, b.expectedVersion, b.topicID, b.locked); });
    app.get("/subjects/:subjectID/history", r => { const q = pageSchema.parse(r.query); return library.history(userID(r), parseID(r, "subjectID"), q.cursor ? uuid.parse(q.cursor) : undefined, q.limit); });
    app.get("/subjects/:subjectID/history/:revisionID", r => library.revision(userID(r), parseID(r, "subjectID"), parseID(r, "revisionID")));
    app.post("/subjects/:subjectID/history/:revisionID/undo", r => { const b = mutationSchema.extend({ choices: z.record(z.string(), z.enum(["current", "incoming"])).default({}) }).parse(r.body); return library.undo(userID(r), parseID(r, "subjectID"), parseID(r, "revisionID"), b.operationID, b.expectedVersion, b.choices); });
    app.get("/subjects/:subjectID/sources", async r => { const q = pageSchema.parse(r.query), page = await sources.page(userID(r), parseID(r, "subjectID"), q.cursor ? uuid.parse(q.cursor) : undefined, q.limit); return { ...page, items: page.items.map(sourceDTO) }; });
    app.post("/subjects/:subjectID/sources", { bodyLimit: 25 * 1024 * 1024 }, async r => {
      const q = z.strictObject({ operationID: uuid, title: z.string().min(1).max(240), kind: z.enum(["pdf", "text", "markdown"]) }).parse(r.query);
      if (!Buffer.isBuffer(r.body)) throw new DomainError("INVALID_SOURCE", "Upload source bytes as application/octet-stream.");
      return sources.upload(userID(r), parseID(r, "subjectID"), q.operationID, q.title, q.kind, r.body);
    });
    app.get("/sources/:sourceID", async r => {
      const source = await sources.get(userID(r), parseID(r, "sourceID"));
      const saved = await db.select({ draft: imports.draft }).from(imports).where(and(eq(imports.userId, userID(r)), eq(imports.subjectId, source.subjectId), eq(imports.sourceId, source.id), eq(imports.status, "saved")));
      const reviewNotes = [...new Set(saved.flatMap(row => Array.isArray(row.draft.reviewNotes) ? row.draft.reviewNotes.filter((value): value is string => typeof value === "string") : []))];
      return { ...sourceDTO(source), reviewNotes };
    });
    app.get("/sources/:sourceID/passages", r => { const q = pageSchema.parse(r.query); return sources.passages(userID(r), parseID(r, "sourceID"), q.cursor ? z.coerce.number().int().min(-1).parse(q.cursor) : -1, q.limit); });
    app.get("/sources/:sourceID/download", async (r, reply) => { const source = await sources.get(userID(r), parseID(r, "sourceID")); reply.header("Content-Type", source.kind === "pdf" ? "application/pdf" : "text/plain; charset=utf-8").header("Content-Disposition", "attachment; filename*=UTF-8''" + encodeURIComponent(source.title)); return reply.send(files.stream(source.storageKey)); });
    app.get("/subjects/:subjectID/imports", r => { const q = pageSchema.parse(r.query); return importer.list(userID(r), parseID(r, "subjectID"), q.cursor ? uuid.parse(q.cursor) : undefined, q.limit); });
    app.post("/subjects/:subjectID/imports", r => { const b = z.strictObject({ operationID: uuid, sourceID: uuid, selection: selectionSchema }).parse(r.body); return importer.create(userID(r), parseID(r, "subjectID"), b.sourceID, b.selection, b.operationID); });
    app.get("/imports", r => { const q = pageSchema.parse(r.query); return importer.allDrafts(userID(r), q.cursor ? uuid.parse(q.cursor) : undefined, q.limit); });
    app.get("/imports/:importID", async r => importDTO(await importer.get(userID(r), parseID(r, "importID"))));
    app.post("/imports/:importID/recheck", r => { const b = mutationSchema.extend({ selection: selectionSchema }).parse(r.body); return importer.recheck(userID(r), parseID(r, "importID"), b.operationID, b.expectedVersion, b.selection); });
    app.post("/imports/:importID/passages/:passageID/review", r => { const b = mutationSchema.extend({ reviewed: z.boolean() }).parse(r.body), passageID = z.string().min(1).max(200).parse((r.params as { passageID: string }).passageID); return importer.acknowledgePassage(userID(r), parseID(r, "importID"), b.operationID, b.expectedVersion, passageID, b.reviewed); });
    app.post("/imports/:importID/changes", r => { const b = mutationSchema.extend({ changes: z.array(draftChangeSchema).min(1).max(100) }).parse(r.body); return importer.changeDraft(userID(r), parseID(r, "importID"), b.operationID, b.expectedVersion, b.changes); });
    app.post("/imports/:importID/changes/:changeID/undo", r => { const b = mutationSchema.parse(r.body); return importer.undoDraftChange(userID(r), parseID(r, "importID"), parseID(r, "changeID"), b.operationID, b.expectedVersion); });
    app.post("/imports/:importID/chat", async (r, reply) => {
      const b = z.strictObject({ operationID: uuid, selection: selectionSchema, messages: chatMessages }).parse(r.body);
      const importID = parseID(r, "importID"); await importer.get(userID(r), importID);
      const controller = new AbortController(); reply.raw.once("close", () => controller.abort()); const emit = stream(reply);
      try { const result = await new ChatService(db, ai).draft(userID(r), importID, b.operationID, b.selection, b.messages, AbortSignal.any([shutdown.signal, controller.signal]), text => emit("delta", { text }), value => emit("draftChanged", value)); emit("completed", result); }
      catch (error) { emit("failed", { code: error instanceof DomainError ? error.code : "CHAT_FAILED", message: error instanceof DomainError ? error.message : "The conversation was interrupted. Completed changes were kept." }); }
      finally { if (!reply.raw.destroyed) reply.raw.end(); }
    });
    app.patch("/imports/:importID", r => { const b = mutationSchema.extend({ changes: z.array(z.strictObject({ id: uuid, selected: z.boolean().optional(), name: z.string().min(1).max(240).optional(), fields: object.optional(), acceptMerge: z.boolean().optional(), resolutionAction: z.enum(["apply", "undo", "dismiss", "restore"]).optional() })).max(2000) }).parse(r.body); return importer.edit(userID(r), parseID(r, "importID"), b.operationID, b.expectedVersion, b.changes); });
    app.post("/imports/:importID/save", r => { const b = mutationSchema.extend({ choices: z.record(z.string(), z.enum(["current", "incoming"])).default({}), expectedSubjectVersion: z.number().int().positive().nullable().default(null) }).parse(r.body); return importer.save(userID(r), parseID(r, "importID"), b.operationID, b.expectedVersion, b.choices, b.expectedSubjectVersion); });
    app.delete("/imports/:importID", r => { const b = mutationSchema.parse(r.body); return importer.delete(userID(r), parseID(r, "importID"), b.operationID, b.expectedVersion); });
    app.get("/subjects/:subjectID/decisions", async r => { const subjectID = parseID(r, "subjectID"), q = pageSchema.parse(r.query); await ownedSubject(db, userID(r), subjectID); const rows = await db.select().from(pendingDecisions).where(and(eq(pendingDecisions.userId, userID(r)), eq(pendingDecisions.subjectId, subjectID), q.cursor ? gt(pendingDecisions.id, uuid.parse(q.cursor)) : undefined)).orderBy(asc(pendingDecisions.id)).limit(q.limit + 1); return { items: rows.slice(0, q.limit).map(d => ({ id: d.id, subjectID: d.subjectId, importID: d.importId, state: d.state, version: d.version })), nextCursor: rows.length > q.limit ? rows[q.limit - 1]!.id : null }; });
    app.get("/jobs/:jobID", async r => jobDTO(requireValue((await db.select().from(jobs).where(and(eq(jobs.userId, userID(r)), eq(jobs.id, parseID(r, "jobID")))))[0])));
    app.get("/subjects/:subjectID/jobs", async r => { const id = parseID(r, "subjectID"), q = pageSchema.parse(r.query); await ownedSubject(db, userID(r), id); const rows = await db.select().from(jobs).where(and(eq(jobs.userId, userID(r)), eq(jobs.subjectId, id), q.cursor ? gt(jobs.id, uuid.parse(q.cursor)) : undefined)).orderBy(asc(jobs.id)).limit(q.limit + 1); return { items: rows.slice(0, q.limit).map(jobDTO), nextCursor: rows.length > q.limit ? rows[q.limit - 1]!.id : null }; });
    app.post("/jobs/:jobID/control", r => { const b = mutationSchema.extend({ action: z.enum(["pause", "resume", "retry", "cancel"]), selection: selectionSchema.nullable().default(null) }).parse(r.body); return queue.control(userID(r), parseID(r, "jobID"), b.operationID, b.expectedVersion, b.action, b.selection); });
    app.get("/subjects/:subjectID/recall", r => { const q = z.strictObject({ topicID: uuid.optional() }).parse(r.query); return recall.dashboard(userID(r), parseID(r, "subjectID"), q.topicID ?? null); });
    app.get("/subjects/:subjectID/recall/materials", r => { const q = pageSchema.parse(r.query); return recall.materials(userID(r), parseID(r, "subjectID"), q.cursor ? uuid.parse(q.cursor) : undefined, q.limit); });
    app.post("/subjects/:subjectID/chat", async (r, reply) => {
      const b = z.strictObject({ selection: selectionSchema, messages: chatMessages }).parse(r.body);
      const subjectID = parseID(r, "subjectID"); await ownedSubject(db, userID(r), subjectID);
      const controller = new AbortController(); reply.raw.once("close", () => controller.abort());
      const emit = stream(reply), service = new ChatService(db, ai);
      try { const result = await service.subject(userID(r), subjectID, b.selection, b.messages, AbortSignal.any([shutdown.signal, controller.signal]), text => emit("delta", { text })); emit("completed", result); }
      catch (error) { emit("failed", { code: error instanceof DomainError ? error.code : "CHAT_FAILED", message: error instanceof DomainError ? error.message : "The conversation was interrupted. Retry to continue." }); }
      finally { if (!reply.raw.destroyed) reply.raw.end(); }
    });
    app.post("/subjects/:subjectID/recall/prepare", r => { const b = z.strictObject({ operationID: uuid, selection: selectionSchema, regenerateMaterialID: uuid.nullable().default(null) }).parse(r.body); return recall.prepare(userID(r), parseID(r, "subjectID"), b.operationID, b.selection, b.regenerateMaterialID); });
    app.post("/subjects/:subjectID/recall/reset", r => { const b = mutationSchema.parse(r.body); return recall.reset(userID(r), parseID(r, "subjectID"), b.operationID, b.expectedVersion); });
    app.get("/subjects/:subjectID/recall/sessions", r => { const q = pageSchema.parse(r.query); return recall.sessions(userID(r), parseID(r, "subjectID"), q.cursor ? uuid.parse(q.cursor) : undefined, q.limit); });
    app.post("/subjects/:subjectID/recall/sessions", r => { const b = z.strictObject({ operationID: uuid, selection: selectionSchema, topicID: uuid.nullable().default(null) }).parse(r.body); return recall.newSession(userID(r), parseID(r, "subjectID"), b.operationID, b.selection, b.topicID); });
    app.get("/recall/sessions/:sessionID", r => recall.presentation(userID(r), parseID(r, "sessionID")));
    app.post("/recall/sessions/:sessionID/answer", r => { const b = mutationSchema.extend({ answer: z.string().min(1).max(20_000), inputValue: z.json().default(null) }).parse(r.body); return recall.answer(userID(r), parseID(r, "sessionID"), b.operationID, b.expectedVersion, b.answer, b.inputValue as JSONObject); });
    app.post("/recall/sessions/:sessionID/answer/edit", r => { const b = mutationSchema.parse(r.body); return recall.editPendingAnswer(userID(r), parseID(r, "sessionID"), b.operationID, b.expectedVersion); });
    app.post("/recall/sessions/:sessionID/unknown", r => { const b = mutationSchema.parse(r.body); return recall.selfReportUnknown(userID(r), parseID(r, "sessionID"), b.operationID, b.expectedVersion); });
    app.post("/recall/sessions/:sessionID/report", r => { const b = mutationSchema.extend({ reason: z.string().trim().min(1).max(2000) }).parse(r.body); return recall.reportQuestion(userID(r), parseID(r, "sessionID"), b.operationID, b.expectedVersion, b.reason); });
    app.post("/recall/sessions/:sessionID/explain", async (r, reply) => {
      const b = mutationSchema.parse(r.body), controller = new AbortController(); reply.raw.once("close", () => controller.abort());
      const explain = () => recall.explain(userID(r), parseID(r, "sessionID"), b.operationID, b.expectedVersion, AbortSignal.any([shutdown.signal, controller.signal]));
      if (!r.headers.accept?.includes("text/event-stream")) return explain();
      const emit = stream(reply);
      try { emit("completed", await explain()); }
      catch (error) { emit("failed", { code: error instanceof DomainError ? error.code : "EXPLANATION_FAILED", message: error instanceof DomainError ? error.message : "The explanation was interrupted. Retry to continue." }); }
      finally { if (!reply.raw.destroyed) reply.raw.end(); }
    });
    app.post("/recall/sessions/:sessionID/assess", async (r, reply) => {
      const b = mutationSchema.extend({ dispute: z.string().min(1).max(3000).nullable().default(null), disputeScope: z.enum(["initial", "conversation"]).default("initial") }).parse(r.body);
      const controller = new AbortController(); reply.raw.once("close", () => controller.abort());
      const assess = () => recall.assess(userID(r), parseID(r, "sessionID"), b.operationID, b.expectedVersion, AbortSignal.any([shutdown.signal, controller.signal]), b.dispute, b.disputeScope);
      if (!r.headers.accept?.includes("text/event-stream")) return assess();
      const emit = stream(reply);
      try { emit("completed", await assess()); }
      catch (error) { emit("failed", { code: error instanceof DomainError ? error.code : "ASSESSMENT_FAILED", message: error instanceof DomainError ? error.message : "The assessment was interrupted. Your answer was kept; retry with the same operation." }); }
      finally { if (!reply.raw.destroyed) reply.raw.end(); }
    });
    app.post("/recall/sessions/:sessionID/advance", r => { const b = mutationSchema.extend({ effort: z.enum(["easy", "someEffort", "veryDifficult"]).nullable().default(null), skip: z.boolean().default(false) }).parse(r.body); return recall.advance(userID(r), parseID(r, "sessionID"), b.operationID, b.expectedVersion, b.effort, b.skip); });
    app.post("/recall/sessions/:sessionID/undo", r => { const b = mutationSchema.parse(r.body); return recall.undo(userID(r), parseID(r, "sessionID"), b.operationID, b.expectedVersion); });
    app.post("/recall/sessions/:sessionID/finish", r => { const b = mutationSchema.parse(r.body); return recall.finishSession(userID(r), parseID(r, "sessionID"), b.operationID, b.expectedVersion); });
    app.patch("/subjects/:subjectID/recall/targets/:targetID", r => { const b = mutationSchema.extend({ excluded: z.boolean() }).parse(r.body); return recall.exclude(userID(r), parseID(r, "subjectID"), parseID(r, "targetID"), b.operationID, b.expectedVersion, b.excluded); });
    app.post("/subjects/:subjectID/recall/targets/:targetID/exposure", r => { const b = mutationSchema.parse(r.body); return recall.expose(userID(r), parseID(r, "subjectID"), parseID(r, "targetID"), b.operationID, b.expectedVersion); });
    app.get("/ai/connections", async r => ({ items: await ai.connections(userID(r)), selfHostedEnabled: process.env.CHATGPT_SELF_HOSTED_ENABLED === "true", apiEnabled: !!process.env.OPENAI_API_KEY_FILE || !!process.env.OPENAI_API_KEY }));
    app.get("/ai/host", async () => ({ hostID: await ai.hostID() }));
    app.post("/ai/connections/handoff", { bodyLimit: 65536 }, r => { const b = z.strictObject({ operationID: uuid, clientID: z.string().max(200), label: z.string().min(1).max(120), accessToken: z.string().min(1).max(16_384), refreshToken: z.string().min(1).max(16_384), idToken: z.string().min(1).max(16_384), expiresAt: z.number().int().positive(), scopes: z.array(z.string().max(120)).max(30) }).parse(r.body); const { operationID, ...credentials } = b; return ai.handoff(userID(r), operationID, credentials); });
    app.delete("/ai/connections/:connectionID", r => { const b = mutationSchema.parse(r.body); return ai.disconnect(userID(r), parseID(r, "connectionID"), b.operationID, b.expectedVersion); });
    app.post("/ai/models", async r => ({ items: await ai.models(userID(r), selectionSchema.parse(r.body)) }));
    app.get("/ai/usage", async r => ({ items: await db.select({ id: aiRequests.id, funding: aiRequests.funding, model: aiRequests.model, status: aiRequests.status, inputTokens: aiRequests.inputTokens, outputTokens: aiRequests.outputTokens, createdAt: aiRequests.createdAt }).from(aiRequests).where(eq(aiRequests.userId, userID(r))).orderBy(desc(aiRequests.createdAt)).limit(100) }));
    app.get("/preferences", async r => { const row = (await db.select().from(preferences).where(eq(preferences.userId, userID(r))))[0]; return { version: row?.version ?? 0, values: row?.values ?? {} }; });
    app.put("/preferences", async r => { const b = z.strictObject({ operationID: uuid, expectedVersion: z.number().int().nonnegative(), values: object }).parse(r.body), owner = userID(r);
      return mutation(db, owner, b.operationID, { action: "preferences", ...b }, async tx => {
        await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${owner + ":preferences"}, 0))`);
        const previous = (await tx.select().from(preferences).where(eq(preferences.userId, owner)))[0]; expected(previous?.version ?? 0, b.expectedVersion);
        await tx.insert(preferences).values({ userId: owner, values: b.values as JSONObject, version: b.expectedVersion + 1 }).onConflictDoUpdate({ target: preferences.userId, set: { values: b.values as JSONObject, version: b.expectedVersion + 1 } });
        await invalidate(tx, owner, "preferences", null, b.expectedVersion + 1); return { version: b.expectedVersion + 1 };
      });
    });
    app.get("/operations/:operationID", async r => {
      const { operations } = await import("@knowledge/backend"); const row = requireValue((await db.select().from(operations).where(and(eq(operations.userId, userID(r)), eq(operations.id, parseID(r, "operationID")))))[0]); return { status: row.response ? "completed" : row.leaseExpiresAt && row.leaseExpiresAt > new Date() ? "processing" : "retryable", response: row.response };
    });
    app.get("/events", async (r, reply) => {
      const owner = userID(r);
      let cursor = Number((await db.select({ id: sql<number>`coalesce(max(${events.id}),0)` }).from(events).where(eq(events.userId, owner)))[0]?.id ?? 0), busy = false;
      const emit = stream(reply);
      const controller = new AbortController(), close = () => controller.abort(); reply.raw.once("close", close); shutdown.signal.addEventListener("abort", close, { once: true });
      emit("invalidate", { resource: "all" });
      const poll = async () => {
        if (busy || controller.signal.aborted) return; busy = true;
        try {
          const active = await auth.api.getSession({ headers: authHeaders(r, config) });
          if (active?.user.id !== owner) { emit("unauthorized", {}); controller.abort(); return; }
          const rows = await db.select().from(events).where(and(eq(events.userId, owner), gt(events.id, cursor))).orderBy(asc(events.id)).limit(100);
          for (const e of rows) { cursor = e.id; emit("invalidate", { id: String(e.id), resource: e.resource, subjectID: e.subjectId, version: e.version }); }
          if (!rows.length) emit("heartbeat", {});
        } catch { emit("reconnect", {}); controller.abort(); }
        finally { busy = false; }
      };
      const timer = setInterval(() => { void poll(); }, 3000);
      await new Promise<void>(resolve => { controller.signal.addEventListener("abort", () => resolve(), { once: true }); if (controller.signal.aborted) resolve(); });
      clearInterval(timer); shutdown.signal.removeEventListener("abort", close); if (!reply.raw.destroyed) reply.raw.end();
    });
    app.get("/operations/status", async r => {
      const owner = userID(r), now = new Date();
      const queue = await db.select({ status: jobs.status, count: sql<number>`count(*)::int`, oldest: sql<Date | null>`min(${jobs.createdAt})`, expiredLeases: sql<number>`count(*) filter (where ${jobs.status}='running' and ${jobs.leaseExpiresAt}<${now})::int` }).from(jobs).where(eq(jobs.userId, owner)).groupBy(jobs.status);
      const usage = await db.select({ funding: aiRequests.funding, status: aiRequests.status, count: sql<number>`count(*)::int`, inputTokens: sql<number>`coalesce(sum(${aiRequests.inputTokens}),0)::bigint`, outputTokens: sql<number>`coalesce(sum(${aiRequests.outputTokens}),0)::bigint` }).from(aiRequests).where(eq(aiRequests.userId, owner)).groupBy(aiRequests.funding, aiRequests.status);
      return { worker: (await db.select({ updatedAt: workerHeartbeats.updatedAt }).from(workerHeartbeats).orderBy(desc(workerHeartbeats.updatedAt)).limit(1))[0]?.updatedAt ?? null, queue, usage, storage: await files.capacity(), limits: { activeJobs: Number(process.env.WORKER_CONCURRENCY ?? 2), aiRequests: null, userAIRequests: null, dailyAPIRequests: Number(process.env.AI_API_DAILY_REQUEST_LIMIT ?? 0) } };
    });
  }, { prefix: "/api/v1" });
}
