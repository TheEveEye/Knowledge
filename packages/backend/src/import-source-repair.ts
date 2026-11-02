import { and, asc, eq, inArray, sql } from "drizzle-orm";
import type { Database } from "./database.js";
import { invalidate, jsonArray, jsonObject, ownedSubject, requireValue } from "./core.js";
import { extractPassages, FileStore, storePassages } from "./files.js";
import { batchPlan, extractionProgress, sourceBatches } from "./import-batches.js";
import { entities, imports, jobs, passages, sources } from "./schema.js";

/** Repair coarse development extraction only before any accepted work references its passages. */
export async function repairPendingImportSource(db: Database, files: FileStore, userId: string, sourceID: string) {
  const source = requireValue((await db.select().from(sources).where(and(eq(sources.userId, userId), eq(sources.id, sourceID))))[0]);
  const previous = await db.select().from(passages).where(and(eq(passages.userId, userId), eq(passages.sourceId, sourceID))).orderBy(asc(passages.ordinal));
  if (source.status !== "ready" || !previous.some(p => /[\r\n]/.test(p.text) || Array.from(p.text).length > 1800)) return { repaired: false };
  const canonical = await extractPassages(await files.bytes(source.storageKey), source.kind), chunks = sourceBatches(canonical);
  return db.transaction(async tx => {
    await ownedSubject(tx, userId, source.subjectId, true);
    const related = await tx.select().from(imports).where(and(eq(imports.userId, userId), eq(imports.sourceId, sourceID))).for("update");
    if (related.some(row => row.status === "saved" || jsonArray(row.draft.entries).length || Object.keys(row.checkpoint).length)) return { repaired: false };
    const work = related.length ? await tx.select().from(jobs).where(and(eq(jobs.userId, userId), inArray(jobs.importId, related.map(row => row.id)))).for("update") : [];
    // Never reinterpret a completed batch, a saved reconciliation, or an in-flight request.
    if (work.some(job => job.status === "running" || job.input.recheck === true || Object.keys(jsonObject(job.checkpoint.batches ?? {})).length || Object.keys(job.checkpoint).some(key => !["batchPlan", "batches"].includes(key)))) return { repaired: false };
    const linked = await tx.select({ id: entities.id }).from(entities).where(and(eq(entities.userId, userId), eq(entities.subjectId, source.subjectId), sql`${entities.record}::text LIKE ${"%" + sourceID + "%"}`)).limit(1);
    if (linked.length) return { repaired: false };
    await storePassages(tx, userId, source.subjectId, sourceID, canonical);
    const checkpoint = { batchPlan: batchPlan(chunks) };
    for (const job of work) {
      if (job.kind !== "import" || ["completed", "cancelled"].includes(job.status)) continue;
      await tx.update(jobs).set({ checkpoint, progress: extractionProgress(canonical, chunks, checkpoint), version: job.version + 1, updatedAt: new Date() }).where(and(eq(jobs.userId, userId), eq(jobs.id, job.id)));
      await invalidate(tx, userId, "jobs", source.subjectId, job.version + 1);
    }
    await invalidate(tx, userId, "sources", source.subjectId, 1);
    return { repaired: true, passages: canonical.length, batches: chunks.length };
  });
}
