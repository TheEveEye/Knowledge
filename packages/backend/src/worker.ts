import { randomUUID } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { setTimeout as delay } from "node:timers/promises";
import { AIService } from "./ai.js";
import { DomainError, requireValue, stringValue } from "./core.js";
import { connectDatabase } from "./database.js";
import { extractPassages, FileStore, storePassages } from "./files.js";
import { ImportService } from "./imports.js";
import { JobQueue, type ClaimedJob } from "./jobs.js";
import { RecallService } from "./recall.js";
import { sources } from "./schema.js";
import { LibraryService } from "./library.js";

export async function runWorker(signal: AbortSignal) {
  const { db, pool } = connectDatabase(), id = randomUUID(), concurrency = Number(process.env.WORKER_CONCURRENCY ?? 2);
  if (!Number.isSafeInteger(concurrency) || concurrency < 1 || concurrency > 16) throw new Error("Invalid WORKER_CONCURRENCY");
  const queue = new JobQueue(db, concurrency), files = new FileStore(), ai = new AIService(db, pool), importer = new ImportService(db, ai, queue), recall = new RecallService(db, ai, queue);
  const running = new Map<string, Promise<void>>(); let lastCleanup = 0, lastHeartbeat = 0;
  async function processJob(job: ClaimedJob) {
    const controller = new AbortController(), combined = AbortSignal.any([signal, controller.signal]); let beating = false;
    const heartbeat = setInterval(() => { if (beating) return; beating = true; void queue.heartbeat(job).catch(() => controller.abort()).finally(() => { beating = false; }); }, 15_000);
    try {
      if (job.kind === "extract") {
        const source = requireValue((await db.select().from(sources).where(and(eq(sources.userId, job.userId), eq(sources.subjectId, job.subjectId), eq(sources.id, stringValue(job.input.sourceID)))))[0]);
        const extracted = await extractPassages(await files.bytes(source.storageKey), source.kind); combined.throwIfAborted();
        await queue.complete(job, tx => storePassages(tx, job.userId, job.subjectId, source.id, extracted));
      } else if (job.kind === "import") await importer.process(job, combined);
      else if (job.kind === "prepareCommit") await importer.commit(job, combined);
      else if (job.kind === "prepareRecall") await recall.generate(job, combined);
      else if (job.kind === "prepareUndo") await new LibraryService(db).processUndo(job, queue);
      else throw new DomainError("UNKNOWN_JOB", "This job requires a newer worker.");
    } catch (error) {
      if (!signal.aborted) {
        try { await queue.fail(job, error); } catch { processError("Could not checkpoint interrupted job"); }
      }
    } finally { clearInterval(heartbeat); running.delete(job.leaseId); }
  }
  try {
    while (!signal.aborted) {
      if (Date.now() - lastHeartbeat > 10_000) { await queue.workerHeartbeat(id); lastHeartbeat = Date.now(); }
      if (Date.now() - lastCleanup > 300_000 && !running.size) { await files.cleanup(db); lastCleanup = Date.now(); }
      while (!signal.aborted && running.size < concurrency) {
        const job = await queue.claim(); if (!job) break;
        const promise = processJob(job); running.set(job.leaseId, promise);
      }
      await delay(1000, undefined, { signal }).catch(() => {});
    }
  } finally {
    const leases = [...running.keys()]; await Promise.allSettled([...running.values()]); await queue.shutdown(leases); await pool.end();
  }
}
function processError(message: string) { process.stderr.write(message + "\n"); }
