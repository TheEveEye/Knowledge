import { randomUUID } from "node:crypto";
import { and, asc, eq, gt, inArray, isNull, lt, or, sql } from "drizzle-orm";
import type { AISelection, JSONObject, Job } from "@knowledge/contracts";
import type { Database, Transaction } from "./database.js";
import { DomainError, invalidate, mutation, ownedSubject, requireValue } from "./core.js";
import { imports, jobs, sources, workerHeartbeats } from "./schema.js";

export type ClaimedJob = typeof jobs.$inferSelect & { leaseId: string };
export const jobDisplayColumns = { id: jobs.id, subjectId: jobs.subjectId, importId: jobs.importId,
  input: sql<JSONObject>`jsonb_build_object('sourceID', ${jobs.input}->'sourceID')`, kind: jobs.kind, status: jobs.status,
  version: jobs.version, progress: jobs.progress, error: jobs.error, selection: jobs.selection, createdAt: jobs.createdAt, updatedAt: jobs.updatedAt };
type DisplayJob = Pick<typeof jobs.$inferSelect, keyof typeof jobDisplayColumns>;
export const jobDTO = (j: DisplayJob): Job => ({ id: j.id, subjectID: j.subjectId, importID: j.importId, sourceID: typeof j.input.sourceID === "string" ? j.input.sourceID : null, kind: j.kind as Job["kind"], status: j.status as Job["status"], version: j.version, progress: j.progress, error: j.error, selection: j.selection, createdAt: j.createdAt.toISOString(), updatedAt: j.updatedAt.toISOString() });
export class JobQueue {
  constructor(readonly db: Database, readonly limit = 2) {}
  async claim(): Promise<ClaimedJob | null> {
    return this.db.transaction(async tx => {
      await tx.execute(sql`SELECT pg_advisory_xact_lock(782115904)`);
      const active = await tx.select({ id: jobs.id }).from(jobs).where(and(eq(jobs.status, "running"), gt(jobs.leaseExpiresAt, new Date())));
      if (active.length >= this.limit) return null;
      const row = (await tx.select().from(jobs).where(and(lt(jobs.availableAt, new Date()),
        or(eq(jobs.status, "queued"), and(eq(jobs.status, "running"), or(isNull(jobs.leaseExpiresAt), lt(jobs.leaseExpiresAt, new Date()))))))
        .orderBy(asc(jobs.availableAt), asc(jobs.id)).limit(1).for("update", { skipLocked: true }))[0];
      if (!row) return null;
      if (row.attempts >= 5) {
        await tx.update(jobs).set({ status: "failed", error: "Processing was interrupted repeatedly. Retry to continue from saved progress.", leaseId: null, leaseExpiresAt: null, version: row.version + 1 }).where(eq(jobs.id, row.id));
        await invalidate(tx, row.userId, "jobs", row.subjectId, row.version + 1); return null;
      }
      const claimed = requireValue((await tx.update(jobs).set({ status: "running", leaseId: randomUUID(), leaseExpiresAt: new Date(Date.now() + 60_000), attempts: row.attempts + 1, updatedAt: new Date(), version: row.version + 1 }).where(eq(jobs.id, row.id)).returning())[0]);
      await invalidate(tx, row.userId, "jobs", row.subjectId, claimed.version);
      return { ...claimed, leaseId: requireValue(claimed.leaseId) };
    });
  }
  async heartbeat(job: ClaimedJob) {
    const result = await this.db.update(jobs).set({ leaseExpiresAt: new Date(Date.now() + 60_000) }).where(and(eq(jobs.id, job.id), eq(jobs.leaseId, job.leaseId), eq(jobs.status, "running"), gt(jobs.leaseExpiresAt, new Date()))).returning({ id: jobs.id });
    if (!result.length) throw new DomainError("LEASE_LOST", "Processing ownership changed.", 409);
  }
  async fenced<T>(job: ClaimedJob, work: (tx: Transaction, current: typeof jobs.$inferSelect) => Promise<T>): Promise<T> {
    return this.db.transaction(async tx => {
      // Subject deletion and all result commits use the same row lock.
      await ownedSubject(tx, job.userId, job.subjectId, true);
      const row = requireValue((await tx.select().from(jobs).where(and(eq(jobs.id, job.id), eq(jobs.userId, job.userId))).for("update"))[0]);
      if (row.leaseId !== job.leaseId || row.status !== "running" || !row.leaseExpiresAt || row.leaseExpiresAt <= new Date()) throw new DomainError("LEASE_LOST", "Processing ownership changed.", 409);
      return work(tx, row);
    });
  }
  async checkpoint(job: ClaimedJob, checkpoint: JSONObject, progress: JSONObject) {
    await this.fenced(job, async (tx, current) => {
      await tx.update(jobs).set({ checkpoint, progress: { ...current.progress, ...progress }, updatedAt: new Date(), version: current.version + 1 }).where(eq(jobs.id, job.id));
      await invalidate(tx, job.userId, "jobs", job.subjectId, current.version + 1);
    });
  }
  async report(job: ClaimedJob, progress: JSONObject) {
    await this.fenced(job, async (tx, current) => {
      // Display-only stream updates do not invalidate a user's Pause/Resume version.
      await tx.update(jobs).set({ progress: { ...current.progress, ...progress }, updatedAt: new Date() }).where(eq(jobs.id, job.id));
      await invalidate(tx, job.userId, "jobs", job.subjectId, current.version);
    });
  }
  async complete(job: ClaimedJob, work: (tx: Transaction) => Promise<void>) {
    await this.fenced(job, async (tx, current) => {
      await work(tx);
      await tx.update(jobs).set({ status: "completed", leaseId: null, leaseExpiresAt: null, updatedAt: new Date(), version: current.version + 1 }).where(eq(jobs.id, job.id));
      await invalidate(tx, job.userId, "jobs", job.subjectId, current.version + 1);
    });
  }
  async fail(job: ClaimedJob, error: unknown) {
    if (error instanceof DomainError && error.code === "LEASE_LOST") return;
    const transient = !(error instanceof DomainError) || ["PROVIDER_UNAVAILABLE", "AI_BUSY", "HEAD_CHANGED"].includes(error.code);
    const busy = error instanceof DomainError && error.code === "AI_BUSY";
    const status = transient && (busy || job.attempts < 5) ? "queued" : error instanceof DomainError && ["AI_UNAUTHORIZED", "AI_LIMIT", "AI_DISCONNECTED"].includes(error.code) ? "blocked" : "failed";
    await this.fenced(job, async (tx, current) => {
      await tx.update(jobs).set({ status, error: error instanceof DomainError ? error.message : "Processing is temporarily unavailable.", ...(busy ? { attempts: Math.max(0, current.attempts - 1) } : {}), leaseId: null, leaseExpiresAt: null, availableAt: new Date(Date.now() + (busy ? 3000 : Math.min(300_000, 5000 * 2 ** job.attempts))), updatedAt: new Date(), version: current.version + 1 }).where(eq(jobs.id, job.id));
      if (job.kind === "extract" && status === "failed") await tx.update(sources).set({ status: "failed", error: error instanceof DomainError ? error.message : "Source preparation failed. Retry processing." }).where(and(eq(sources.userId, job.userId), eq(sources.subjectId, job.subjectId), eq(sources.id, String(job.input.sourceID))));
      await invalidate(tx, job.userId, "jobs", job.subjectId, current.version + 1);
    }).catch(e => { if (!(e instanceof DomainError && ["LEASE_LOST", "NOT_FOUND"].includes(e.code))) throw e; });
  }
  async control(userId: string, jobID: string, operationID: string, version: number, action: "pause" | "resume" | "retry" | "cancel", selection: AISelection | null = null) {
    return mutation(this.db, userId, operationID, { action: "job:" + action, jobID, version, selection }, async tx => {
      const initial = requireValue((await tx.select().from(jobs).where(and(eq(jobs.id, jobID), eq(jobs.userId, userId))))[0]);
      await ownedSubject(tx, userId, initial.subjectId, true);
      const job = requireValue((await tx.select().from(jobs).where(and(eq(jobs.id, jobID), eq(jobs.userId, userId))).for("update"))[0]);
      if (job.version !== version) throw new DomainError("VERSION_CONFLICT", "This operation’s status changed. Refresh and try again.", 409);
      if (["completed", "cancelled"].includes(job.status)) throw new DomainError("JOB_FINISHED", "This operation has finished.", 409);
      if (selection && (!["paused", "blocked", "failed"].includes(job.status) || !["resume", "retry"].includes(action) || !job.selection)) throw new DomainError("INVALID_JOB_CONTROL", "Pause this AI operation before explicitly changing its funding or model.", 409);
      const status = action === "pause" ? "paused" : action === "cancel" ? "cancelled" : "queued";
      if (job.importId && (await tx.select().from(imports).where(and(eq(imports.id, job.importId), eq(imports.userId, userId))))[0]?.status === "saved") throw new DomainError("IMPORT_SAVED", "This import has already been saved.", 409);
      await tx.update(jobs).set({ status, ...(selection ? { selection, aiConnectionId: selection.connectionID } : {}), leaseId: null, leaseExpiresAt: null, attempts: 0, error: null, availableAt: new Date(), version: version + 1, updatedAt: new Date() }).where(eq(jobs.id, jobID));
      await invalidate(tx, userId, "jobs", job.subjectId, version + 1); return { version: version + 1, status };
    });
  }
  async shutdown(ids: string[]) {
    if (ids.length) await this.db.update(jobs).set({ status: "queued", leaseId: null, leaseExpiresAt: null }).where(and(inArray(jobs.leaseId, ids), eq(jobs.status, "running")));
  }
  async workerHeartbeat(id: string) { await this.db.insert(workerHeartbeats).values({ id, revision: process.env.APP_REVISION ?? "development" }).onConflictDoUpdate({ target: workerHeartbeats.id, set: { updatedAt: new Date() } }); }
}
