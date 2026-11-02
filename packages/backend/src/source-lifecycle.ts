import { and, eq, sql } from "drizzle-orm";
import type { Transaction } from "./database.js";
import { invalidate } from "./core.js";
import { entities, entityVersions, fileCleanup, imports, jobs, learningEvents, operations, pendingDecisions, recallMaterials, recallSessions, revisions, sources } from "./schema.js";

/** Called after discarding a draft, with its owned subject locked in the same transaction. */
export async function removeUnusedImportSource(tx: Transaction, userId: string, subjectID: string, sourceID: string) {
  const source = (await tx.select().from(sources).where(and(eq(sources.userId, userId), eq(sources.subjectId, subjectID), eq(sources.id, sourceID))).for("update"))[0];
  if (!source) return false;
  // Match the complete JSON string value, not a UUID substring. Conservatively retain
  // any reference, including retired knowledge, immutable versions and learning history.
  const reference = '%"' + sourceID + '"%';
  const [usage] = await tx.select({ retained: sql<boolean>`
    EXISTS(SELECT 1 FROM ${imports} WHERE ${imports.userId}=${userId} AND
      (${imports.sourceId}=${sourceID} OR ${imports.draft}::text LIKE ${reference} OR ${imports.checkpoint}::text LIKE ${reference}))
    OR EXISTS(SELECT 1 FROM ${entities} WHERE ${entities.userId}=${userId} AND ${entities.record}::text LIKE ${reference})
    OR EXISTS(SELECT 1 FROM ${entityVersions} WHERE ${entityVersions.userId}=${userId} AND ${entityVersions.payload}::text LIKE ${reference})
    OR EXISTS(SELECT 1 FROM ${revisions} WHERE ${revisions.userId}=${userId} AND ${revisions.changes}::text LIKE ${reference})
    OR EXISTS(SELECT 1 FROM ${recallMaterials} WHERE ${recallMaterials.userId}=${userId} AND
      (${recallMaterials.snapshot}::text LIKE ${reference} OR ${recallMaterials.bank}::text LIKE ${reference}))
    OR EXISTS(SELECT 1 FROM ${recallSessions} WHERE ${recallSessions.userId}=${userId} AND ${recallSessions.state}::text LIKE ${reference})
    OR EXISTS(SELECT 1 FROM ${learningEvents} WHERE ${learningEvents.userId}=${userId} AND ${learningEvents.payload}::text LIKE ${reference})
    OR EXISTS(SELECT 1 FROM ${pendingDecisions} WHERE ${pendingDecisions.userId}=${userId} AND ${pendingDecisions.state}::text LIKE ${reference})
    OR EXISTS(SELECT 1 FROM ${jobs} WHERE ${jobs.userId}=${userId} AND ${jobs.kind}<>'extract' AND
      (${jobs.input}::text LIKE ${reference} OR ${jobs.checkpoint}::text LIKE ${reference}))
  ` }).from(sources).where(and(eq(sources.userId, userId), eq(sources.subjectId, subjectID), eq(sources.id, sourceID))).limit(1);
  if (!usage || usage.retained) return false;
  // Removing source extraction jobs fences any late extraction/checkpoint writes.
  await tx.delete(jobs).where(and(eq(jobs.userId, userId), eq(jobs.subjectId, subjectID), sql`${jobs.input}->>'sourceID'=${sourceID}`));
  await tx.update(operations).set({ response: { resourceDeleted: true }, leaseId: null, leaseExpiresAt: null })
    .where(and(eq(operations.userId, userId), sql`${operations.response}->>'sourceID'=${sourceID}`));
  await tx.delete(sources).where(and(eq(sources.userId, userId), eq(sources.subjectId, subjectID), eq(sources.id, sourceID)));
  // Bytes remain recoverable through the existing backup-coordinated delayed sweep.
  const after = new Date(Date.now() + 86_400_000);
  await tx.insert(fileCleanup).values({ storageKey: source.storageKey, after }).onConflictDoUpdate({ target: fileCleanup.storageKey, set: { after } });
  await invalidate(tx, userId, "sources", subjectID, 1);
  await invalidate(tx, userId, "jobs", subjectID, 1);
  return true;
}
