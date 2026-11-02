import { randomUUID } from "node:crypto";
import { and, asc, desc, eq, gt, inArray, sql } from "drizzle-orm";
import type { EntityChange, EntityKind, JSONObject, LibraryEntity, Subject } from "@knowledge/contracts";
import type { Database, Transaction } from "./database.js";
import { DomainError, canonical, expected, hash, invalidate, jsonArray, jsonObject, mutation, normalizeName, ownedSubject, requireValue, stringValue } from "./core.js";
import { entities, entityLinks, entityVersions, fileCleanup, imports, jobs, learningEvents, operations, passages, pendingDecisions, recallMaterials, recallSessions, recallTargets, revisions, sources, subjects } from "./schema.js";
import { z } from "zod";
import { JobQueue, type ClaimedJob } from "./jobs.js";

const subjectDTO = (row: typeof subjects.$inferSelect): Subject => ({ id: row.id, name: row.name, version: row.version, revisionID: row.revisionId, createdAt: row.createdAt.toISOString(), updatedAt: row.updatedAt.toISOString() });
const editable: Record<EntityKind, Set<string>> = {
  concept: new Set(["name", "aliases", "explanation", "reviewNote"]), fact: new Set(["statement", "qualifications", "reviewNote"]),
  connection: new Set(["explanation", "reviewNote"]), topic: new Set(["name", "parentID", "sortOrder"]),
  placement: new Set(["topicID", "isLocked", "reason"]), contribution: new Set(),
};
export async function snapshot(tx: Transaction | Database, userId: string, subjectID: string) {
  return (await tx.select().from(entities).where(and(eq(entities.userId, userId), eq(entities.subjectId, subjectID)))).map(r => r.record);
}
export async function revisionSnapshot(tx: Transaction | Database, userId: string, subjectID: string, revisionID: string) {
  const revision = requireValue((await tx.select().from(revisions).where(and(eq(revisions.userId, userId), eq(revisions.subjectId, subjectID), eq(revisions.id, revisionID))))[0]);
  const hashes = Object.values(revision.manifest);
  if (!hashes.length) return [];
  const versions = await tx.select().from(entityVersions).where(and(eq(entityVersions.userId, userId), inArray(entityVersions.hash, hashes)));
  if (versions.length !== new Set(hashes).size) throw new DomainError("DAMAGED_HISTORY", "A saved library version is unavailable.", 409);
  return versions.map(v => v.payload);
}
function references(record: LibraryEntity): { id: string; kind: EntityKind; field: string }[] {
  const result: { id: string; kind: EntityKind; field: string }[] = [];
  const single: [string, EntityKind][] = [["conceptID", "concept"], ["fromConceptID", "concept"], ["toConceptID", "concept"], ["parentID", "topic"], ["topicID", "topic"]];
  for (const [field, kind] of single) { const value = record.fields[field]; if (typeof value === "string") result.push({ id: value, kind, field }); }
  for (const id of jsonArray(record.fields.supportingFactIDs)) if (typeof id === "string") result.push({ id, kind: "fact", field: "supportingFactIDs" });
  if (record.redirectID) result.push({ id: record.redirectID, kind: record.kind, field: "redirectID" });
  if (record.kind === "contribution") result.push({ id: stringValue(record.fields.entityID), kind: stringValue(record.fields.entityKind) as EntityKind, field: "entityID" });
  return result;
}
export async function validateGraph(tx: Transaction, userId: string, subjectId: string, records: LibraryEntity[]) {
  const map = new Map(records.map(r => [r.id, r]));
  if (map.size !== records.length) throw new DomainError("INVALID_LIBRARY", "Duplicate library identities.");
  const subjectSources = await tx.select().from(sources).where(and(eq(sources.userId, userId), eq(sources.subjectId, subjectId)));
  const ready = new Set(subjectSources.filter(s => s.status === "ready").map(s => s.id));
  const sourcePassages = await tx.select().from(passages).where(and(eq(passages.userId, userId), eq(passages.subjectId, subjectId)));
  const passageMap = new Map(sourcePassages.map(p => [p.sourceId + "/" + p.id, p.text]));
  const normalize = (text: string) => text.normalize("NFKC").replace(/\u00ad/g, "").replace(/\s+/g, " ").trim();
  for (const record of records) {
    if (record.subjectID !== subjectId) throw new DomainError("INVALID_LIBRARY", "A library entry belongs to another subject.");
    for (const ref of references(record)) {
      const target = map.get(ref.id);
      if (!target || target.kind !== ref.kind || (!record.isRetired && target.isRetired && !target.redirectID)) throw new DomainError("INVALID_REFERENCE", "A library reference is unavailable.");
    }
    if (["concept", "fact", "connection"].includes(record.kind)) {
      const evidence = jsonArray(record.fields.evidence);
      if (evidence.length === 0) throw new DomainError("INVALID_EVIDENCE", "A library entry has no source evidence.");
      for (const raw of evidence) {
        const e = jsonObject(raw), sourceID = stringValue(e.sourceID), quote = normalize(stringValue(e.quote));
        if (!ready.has(sourceID) || !quote || !normalize(passageMap.get(sourceID + "/" + stringValue(e.segmentID)) ?? "").includes(quote)) throw new DomainError("INVALID_EVIDENCE", "An evidence quotation does not match the original source.");
      }
    }
    if (record.kind === "connection" && (record.fields.fromConceptID === record.fields.toConceptID || jsonArray(record.fields.supportingFactIDs).length === 0)) throw new DomainError("INVALID_CONNECTION", "Connections require different endpoints and supporting facts.");
    if (record.kind === "topic") {
      const visited = new Set([record.id]); let cursor = record;
      while (typeof cursor.fields.parentID === "string") {
        if (visited.has(cursor.fields.parentID) || visited.size >= 3) throw new DomainError("INVALID_TOPIC", "Topics support at most three levels and cannot contain cycles.");
        visited.add(cursor.fields.parentID); cursor = requireValue(map.get(cursor.fields.parentID));
      }
    }
    if (record.isRetired && record.redirectID) {
      const visited = new Set([record.id]); let cursor = record;
      while (cursor.redirectID) { if (visited.has(cursor.redirectID)) throw new DomainError("INVALID_REDIRECT", "Library redirects cannot contain cycles."); visited.add(cursor.redirectID); cursor = requireValue(map.get(cursor.redirectID)); }
    }
  }
  const placements = records.filter(r => r.kind === "placement" && !r.isRetired).map(r => r.fields.conceptID);
  if (new Set(placements).size !== placements.length) throw new DomainError("INVALID_PLACEMENT", "A concept can have only one topic placement.");
  const siblings = records.filter(r => r.kind === "topic" && !r.isRetired).map(r => String(r.fields.parentID ?? "root") + "/" + normalizeName(stringValue(r.fields.name)));
  if (new Set(siblings).size !== siblings.length) throw new DomainError("INVALID_TOPIC", "Sibling topics must have distinct names.");
}
export async function writeRevision(tx: Transaction, userId: string, subject: typeof subjects.$inferSelect, operationID: string,
  before: LibraryEntity[], after: LibraryEntity[], origin: string, title: string, undoesRevisionID: string | null = null) {
  await validateGraph(tx, userId, subject.id, after);
  const old = new Map(before.map(r => [r.id, r])), next = new Map(after.map(r => [r.id, r]));
  const changes: EntityChange[] = [...new Set([...old.keys(), ...next.keys()])].sort().flatMap(id => {
    const a = old.get(id) ?? null, b = next.get(id) ?? null;
    return canonical(a) === canonical(b) ? [] : [{ before: a, after: b }];
  });
  const revisionID = randomUUID(), manifest: Record<string, string> = {};
  const changedIDs = new Set(changes.map(c => (c.after ?? c.before)!.id));
  for (const record of after) {
    const contentHash = hash(record); manifest[record.kind + "/" + record.id] = contentHash;
    if (!changedIDs.has(record.id)) continue;
    await tx.insert(entityVersions).values({ userId, hash: contentHash, payload: record }).onConflictDoNothing();
    await tx.insert(entities).values({ userId, subjectId: subject.id, id: record.id, kind: record.kind, record })
      .onConflictDoUpdate({ target: [entities.userId, entities.subjectId, entities.id], set: { record, updatedAt: new Date() } });
  }
  // Clear links first so physical placement removals cannot violate another record's FK.
  if (changedIDs.size) await tx.delete(entityLinks).where(and(eq(entityLinks.userId, userId), eq(entityLinks.subjectId, subject.id), inArray(entityLinks.fromId, [...changedIDs])));
  const removed = before.filter(r => !next.has(r.id));
  if (removed.some(r => r.kind !== "placement")) throw new DomainError("INVALID_LIBRARY", "Knowledge identities must be retired rather than deleted.");
  if (removed.length) await tx.delete(entities).where(and(eq(entities.userId, userId), eq(entities.subjectId, subject.id), inArray(entities.id, removed.map(r => r.id))));
  const links = after.filter(r => changedIDs.has(r.id)).flatMap(r => references(r).map(ref => ({ userId, subjectId: subject.id, fromId: r.id, toId: ref.id, field: ref.field })));
  for (let offset = 0; offset < links.length; offset += 1000) await tx.insert(entityLinks).values(links.slice(offset, offset + 1000)).onConflictDoNothing();
  await tx.insert(revisions).values({ id: revisionID, userId, subjectId: subject.id, parentId: subject.revisionId, operationId: operationID, origin, title,
    summary: changes.length ? `${changes.length} library ${changes.length === 1 ? "change" : "changes"}` : title, changes, manifest, undoesRevisionId: undoesRevisionID });
  const version = subject.version + 1;
  await tx.update(subjects).set({ revisionId: revisionID, version, updatedAt: new Date() }).where(and(eq(subjects.userId, userId), eq(subjects.id, subject.id)));
  // Organizational changes do not invalidate independently verified knowledge.
  const changedConcepts = new Set(changes.filter(c => (c.after ?? c.before)?.kind === "concept" && ["name", "aliases", "explanation"].some(field => canonical(c.before?.fields[field] ?? null) !== canonical(c.after?.fields[field] ?? null))).map(c => (c.after ?? c.before)!.id));
  const changedMaterial = new Set(changes.filter(c => ["fact", "connection"].includes((c.after ?? c.before)!.kind)).map(c => (c.after ?? c.before)!.id));
  for (const record of after) if (["fact", "connection"].includes(record.kind) && [record.fields.conceptID, record.fields.fromConceptID, record.fields.toConceptID].some(id => typeof id === "string" && changedConcepts.has(id))) changedMaterial.add(record.id);
  await tx.update(recallMaterials).set({ revisionId: revisionID }).where(and(eq(recallMaterials.userId, userId), eq(recallMaterials.subjectId, subject.id)));
  if (changedMaterial.size) await tx.update(recallMaterials).set({ status: "stale" }).where(and(eq(recallMaterials.userId, userId), eq(recallMaterials.subjectId, subject.id), inArray(recallMaterials.entityId, [...changedMaterial])));
  const retired = after.filter(r => r.isRetired && ["fact", "connection"].includes(r.kind)).map(r => r.id);
  if (retired.length) await tx.update(recallTargets).set({ retired: true, version: sql`${recallTargets.version}+1` }).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, subject.id), inArray(recallTargets.materialId, retired)));
  await invalidate(tx, userId, "library", subject.id, version);
  return { revisionID, version };
}

export class LibraryService {
  constructor(readonly db: Database) {}
  async undoSuggestion(userId: string, subjectID: string, entityID: string, sourceID: string, operationID: string, version: number, wordingIndex: number | null) {
    return mutation(this.db, userId, operationID, { action: "undoSavedSuggestion", subjectID, entityID, sourceID, version, wordingIndex }, async tx => {
      const subject = await ownedSubject(tx, userId, subjectID, true); expected(subject.version, version);
      const before = await snapshot(tx, userId, subjectID), after = structuredClone(before), record = requireValue(after.find(r => r.id === entityID && r.kind === "concept" && !r.isRetired));
      const wordings = jsonArray(record.fields.wordings);
      let suggestion: JSONObject;
      if (wordingIndex !== null) {
        const wording = jsonObject(requireValue(wordings[wordingIndex]));
        if (wording.sourceID !== sourceID) throw new DomainError("SUGGESTION_CHANGED", "This saved suggestion changed. Refresh before undoing it.", 409);
        suggestion = jsonObject(wording.resolutionSuggestion);
      } else {
        if (!jsonArray(record.fields.sourceIDs).includes(sourceID)) throw new DomainError("SUGGESTION_UNAVAILABLE", "This source does not belong to the saved concept.");
        suggestion = jsonObject(record.fields.resolutionSuggestion);
      }
      if (suggestion.status !== "applied") throw new DomainError("SUGGESTION_CHANGED", "This suggestion has already been changed.", 409);
      if ((suggestion.changedLibraryName === true || wordingIndex === null && jsonArray(record.fields.sourceIDs).length === 1) && record.fields.name === suggestion.suggestedName && typeof suggestion.previousName === "string") record.fields.name = suggestion.previousName;
      suggestion.status = "dismissed"; record.protectedFields = [...new Set([...record.protectedFields, "name"])];
      if (wordingIndex !== null) record.fields.wordings = wordings;
      const top = jsonObject(record.fields.resolutionSuggestion);
      if (top.status === "applied" && top.suggestedName === suggestion.suggestedName && top.previousName === suggestion.previousName) top.status = "dismissed";
      return writeRevision(tx, userId, subject, operationID, before, after, "edit", "Undid an AI suggestion");
    });
  }
  async list(userId: string, cursor?: string, limit = 50) {
    const rows = await this.db.select().from(subjects).where(and(eq(subjects.userId, userId), cursor ? gt(subjects.id, cursor) : undefined)).orderBy(asc(subjects.id)).limit(limit + 1);
    return { items: rows.slice(0, limit).map(subjectDTO), nextCursor: rows.length > limit ? rows[limit - 1]!.id : null };
  }
  async subject(userId: string, id: string) { return subjectDTO(await ownedSubject(this.db, userId, id)); }
  async entry(userId: string, subjectID: string, entityID: string) {
    await ownedSubject(this.db, userId, subjectID);
    return requireValue((await this.db.select().from(entities).where(and(eq(entities.userId, userId), eq(entities.subjectId, subjectID), eq(entities.id, entityID))))[0]).record;
  }
  async create(userId: string, operationID: string, name: string) {
    return mutation(this.db, userId, operationID, { action: "createSubject", name }, async tx => {
      const normalized = normalizeName(name); if (!normalized || name.trim().length > 160) throw new DomainError("INVALID_NAME", "Give this subject a name of at most 160 characters.");
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${userId + ":subjects"}, 0))`);
      if ((await tx.select().from(subjects).where(and(eq(subjects.userId, userId), eq(subjects.normalizedName, normalized)))).length) throw new DomainError("DUPLICATE_NAME", "A subject with this name already exists.", 409);
      const id = randomUUID(), revisionId = randomUUID();
      const row = requireValue((await tx.insert(subjects).values({ id, userId, name: name.trim(), normalizedName: normalized, revisionId }).returning())[0]);
      await tx.insert(revisions).values({ id: revisionId, userId, subjectId: id, operationId: operationID, origin: "baseline", title: "Created subject", summary: "Created subject", manifest: {}, changes: [] });
      await invalidate(tx, userId, "subjects", id, 1);
      return { subject: subjectDTO(row) as unknown as JSONObject };
    });
  }
  async rename(userId: string, id: string, operationID: string, version: number, name: string) {
    return mutation(this.db, userId, operationID, { action: "renameSubject", subjectID: id, version, name }, async tx => {
      const subject = await ownedSubject(tx, userId, id, true); expected(subject.version, version);
      const normalized = normalizeName(name); if (!normalized || name.trim().length > 160) throw new DomainError("INVALID_NAME", "Give this subject a name of at most 160 characters.");
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${userId + ":subjects"}, 0))`);
      const duplicate = (await tx.select().from(subjects).where(and(eq(subjects.userId, userId), eq(subjects.normalizedName, normalized)))).some(s => s.id !== id);
      if (duplicate) throw new DomainError("DUPLICATE_NAME", "A subject with this name already exists.", 409);
      const records = await snapshot(tx, userId, id);
      const result = await writeRevision(tx, userId, subject, operationID, records, records, "manual", `Renamed “${subject.name}” to “${name.trim()}”`);
      await tx.update(subjects).set({ name: name.trim(), normalizedName: normalized }).where(and(eq(subjects.userId, userId), eq(subjects.id, id)));
      return { ...result, name: name.trim() };
    });
  }
  async delete(userId: string, id: string, operationID: string, version: number) {
    return mutation(this.db, userId, operationID, { action: "deleteSubject", id, version }, async tx => {
      const subject = await ownedSubject(tx, userId, id, true); expected(subject.version, version);
      await tx.update(operations).set({ subjectId: null, response: { resourceDeleted: true }, leaseId: null, leaseExpiresAt: null }).where(and(eq(operations.userId, userId), eq(operations.subjectId, id)));
      const files = await tx.select({ key: sources.storageKey }).from(sources).where(and(eq(sources.userId, userId), eq(sources.subjectId, id)));
      for (const file of files) await tx.insert(fileCleanup).values({ storageKey: file.key, after: new Date(Date.now() + 86_400_000) }).onConflictDoNothing();
      // Explicit dependent order also handles references preserved within revision history.
      for (const table of [learningEvents, recallSessions, recallTargets, recallMaterials, pendingDecisions, jobs, imports, entityLinks, entities, revisions, passages, sources]) {
        await tx.delete(table).where(and(eq(table.userId, userId), eq(table.subjectId, id)));
      }
      await tx.delete(entityVersions).where(and(eq(entityVersions.userId, userId), sql`${entityVersions.payload}->>'subjectID'=${id}`));
      await tx.delete(subjects).where(and(eq(subjects.userId, userId), eq(subjects.id, id)));
      await invalidate(tx, userId, "subjects", id, version + 1);
      return { deleted: true };
    });
  }
  async entries(userId: string, subjectID: string, kind?: EntityKind, cursor?: string, limit = 100, search?: string) {
    await ownedSubject(this.db, userId, subjectID);
    const rows = await this.db.select().from(entities).where(and(eq(entities.userId, userId), eq(entities.subjectId, subjectID),
      kind ? eq(entities.kind, kind) : undefined, cursor ? gt(entities.id, cursor) : undefined,
      search ? sql`${entities.record}::text ILIKE ${"%" + search.replace(/[\\%_]/g, "\\$&") + "%"}` : undefined)).orderBy(asc(entities.id)).limit(limit + 1);
    return { items: rows.slice(0, limit).map(r => r.record), nextCursor: rows.length > limit ? rows[limit - 1]!.id : null };
  }
  async edit(userId: string, subjectID: string, entityID: string, operationID: string, version: number, fields: JSONObject) {
    return mutation(this.db, userId, operationID, { action: "editEntity", subjectID, entityID, version, fields }, async tx => {
      const subject = await ownedSubject(tx, userId, subjectID, true); expected(subject.version, version);
      const before = await snapshot(tx, userId, subjectID), record = requireValue(before.find(r => r.id === entityID));
      if (record.isRetired || Object.keys(fields).some(key => !editable[record.kind].has(key))) throw new DomainError("INVALID_EDIT", "This field cannot be changed here.");
      for (const [field, value] of Object.entries(fields)) {
        const validator = field === "aliases" ? z.array(z.string().min(1).max(240)).max(100) : ["parentID", "topicID"].includes(field) ? z.uuid().nullable() : field === "sortOrder" ? z.number().int().nonnegative().max(1_000_000) : field === "isLocked" ? z.boolean() : field === "reviewNote" ? z.string().max(30_000).nullable() : z.string().min(1).max(30_000);
        if (!validator.safeParse(value).success) throw new DomainError("INVALID_EDIT", "This field has an invalid value.");
        if (["name", "statement", "explanation"].includes(field) && (typeof value !== "string" || !value.trim())) throw new DomainError("INVALID_EDIT", "This field cannot be empty.");
        if (typeof value === "string" && value.length > 30_000) throw new DomainError("INVALID_EDIT", "This field is too long.");
      }
      const after = before.map(r => r.id !== entityID ? r : { ...r, fields: { ...r.fields, ...fields }, protectedFields: [...new Set([...r.protectedFields, ...Object.keys(fields)])].sort() });
      return writeRevision(tx, userId, subject, operationID, before, after, "manual", "Edited " + record.kind);
    });
  }
  async history(userId: string, subjectID: string, cursor?: string, limit = 50) {
    await ownedSubject(this.db, userId, subjectID);
    const rows = await this.db.select().from(revisions).where(and(eq(revisions.userId, userId), eq(revisions.subjectId, subjectID), cursor ? sql`(${revisions.createdAt},${revisions.id}) < (SELECT created_at,id FROM knowledge.subject_revisions WHERE user_id=${userId} AND subject_id=${subjectID} AND id=${cursor})` : undefined)).orderBy(desc(revisions.createdAt), desc(revisions.id)).limit(limit + 1);
    return { items: rows.slice(0, limit).map(r => ({ id: r.id, subjectID: r.subjectId, parentID: r.parentId, operationID: r.operationId, origin: r.origin, title: r.title, summary: r.summary, createdAt: r.createdAt.toISOString(), undoesRevisionID: r.undoesRevisionId })), nextCursor: rows.length > limit ? rows[limit - 1]!.id : null };
  }
  async move(userId: string, subjectID: string, conceptID: string, operationID: string, version: number, topicID: string | null, locked: boolean) {
    return mutation(this.db, userId, operationID, { action: "moveConcept", subjectID, conceptID, version, topicID, locked }, async tx => {
      const subject = await ownedSubject(tx, userId, subjectID, true); expected(subject.version, version);
      const before = await snapshot(tx, userId, subjectID);
      if (!before.some(r => r.id === conceptID && r.kind === "concept" && !r.isRetired) || (topicID && !before.some(r => r.id === topicID && r.kind === "topic" && !r.isRetired))) throw new DomainError("INVALID_PLACEMENT", "Choose an active concept and topic in this subject.");
      const previous = before.find(r => r.kind === "placement" && r.fields.conceptID === conceptID && !r.isRetired);
      const placement: LibraryEntity = { id: previous?.id ?? randomUUID(), subjectID, kind: "placement", fields: { conceptID, topicID, isLocked: locked, reason: null }, protectedFields: locked ? ["topicID", "isLocked"] : [], isRetired: false, redirectID: null };
      const after = [...before.filter(r => r.id !== placement.id), placement];
      return writeRevision(tx, userId, subject, operationID, before, after, "manual", "Moved a concept");
    });
  }
  async revision(userId: string, subjectID: string, revisionID: string) {
    const r = requireValue((await this.db.select().from(revisions).where(and(eq(revisions.userId, userId), eq(revisions.subjectId, subjectID), eq(revisions.id, revisionID))))[0]);
    const ids = new Set(r.changes.flatMap(change => [change.before, change.after].flatMap(record => record ? ["conceptID", "fromConceptID", "toConceptID", "topicID", "parentID"].flatMap(field => typeof record.fields[field] === "string" ? [record.fields[field] as string] : []) : [])));
    const hashes = Object.entries(r.manifest).filter(([key]) => ids.has(key.slice(key.indexOf("/") + 1))).map(([, hash]) => hash);
    const versions = hashes.length ? await this.db.select().from(entityVersions).where(and(eq(entityVersions.userId, userId), inArray(entityVersions.hash, hashes))) : [];
    const names = Object.fromEntries(versions.filter(v => v.payload.subjectID === subjectID && typeof v.payload.fields.name === "string").map(v => [v.payload.id, stringValue(v.payload.fields.name)]));
    return { id: r.id, subjectID: r.subjectId, parentID: r.parentId, operationID: r.operationId, origin: r.origin, title: r.title, summary: r.summary, createdAt: r.createdAt.toISOString(), changes: r.changes, undoesRevisionID: r.undoesRevisionId, names };
  }
  async undo(userId: string, subjectID: string, revisionID: string, operationID: string, version: number, choices: Record<string, "current" | "incoming"> = {}) {
    return mutation(this.db, userId, operationID, { action: "undo", subjectID, revisionID, version, choices }, async tx => {
      const subject = await ownedSubject(tx, userId, subjectID, true); expected(subject.version, version);
      const revision = await this.revision(userId, subjectID, revisionID);
      if (revision.origin !== "import") throw new DomainError("INVALID_UNDO", "Only saved imports can be undone.");
      const job = requireValue((await tx.insert(jobs).values({ userId, subjectId: subjectID, kind: "prepareUndo", input: { revisionID, operationID, version, choices } }).returning())[0]);
      await invalidate(tx, userId, "jobs", subjectID, job.version); return { jobID: job.id };
    });
  }
  async processUndo(job: ClaimedJob, queue: JobQueue) {
    await queue.complete(job, async tx => {
      const userId = job.userId, subjectID = job.subjectId, revisionID = stringValue(job.input.revisionID), operationID = stringValue(job.input.operationID);
      const choices = jsonObject(job.input.choices), subject = await ownedSubject(tx, userId, subjectID, true); expected(subject.version, Number(job.input.version));
      const revision = requireValue((await tx.select().from(revisions).where(and(eq(revisions.userId, userId), eq(revisions.subjectId, subjectID), eq(revisions.id, revisionID))))[0]);
      if (revision.origin !== "import") throw new DomainError("INVALID_UNDO", "Only saved imports can be undone.");
      const already = (await tx.select().from(revisions).where(and(eq(revisions.userId, userId), eq(revisions.subjectId, subjectID), eq(revisions.undoesRevisionId, revisionID))))[0];
      if (already) { await tx.update(jobs).set({ progress: { stage: "completed", result: { revisionID: already.id, version: subject.version } } }).where(eq(jobs.id, job.id)); return; }
      const before = await snapshot(tx, userId, subjectID), map = new Map(before.map(r => [r.id, structuredClone(r)]));
      const conflicts: JSONObject[] = [];
      for (const change of revision.changes) {
        const id = (change.after ?? change.before)!.id, current = map.get(id);
        if (!current) continue;
        if (!change.before) {
          const dependedOn = before.some(r => r.id !== id && !r.isRetired && references(r).some(ref => ref.id === id) && !revision.changes.some(c => c.after?.id === r.id && !c.before));
          if (!dependedOn && canonical(current) === canonical(change.after)) map.set(id, { ...current, isRetired: true });
          continue;
        }
        for (const field of new Set([...Object.keys(change.before.fields), ...Object.keys(change.after?.fields ?? {})])) {
          const old = change.before.fields[field] ?? null, applied = change.after?.fields[field] ?? null, now = current.fields[field] ?? null;
          if (canonical(old) === canonical(applied)) continue;
          if (canonical(now) === canonical(applied)) current.fields[field] = old;
          else if (canonical(now) !== canonical(old)) {
            const key = id + "/" + field;
            if (choices[key] === "incoming") current.fields[field] = old;
            else if (choices[key] !== "current") conflicts.push({ id: key, entityID: id, field, current: now, incoming: old });
          }
        }
      }
      await tx.delete(pendingDecisions).where(and(eq(pendingDecisions.userId, userId), eq(pendingDecisions.subjectId, subjectID), sql`${pendingDecisions.state}->>'revisionID'=${revisionID}`));
      if (conflicts.length) {
        await tx.insert(pendingDecisions).values({ userId, subjectId: subjectID, state: { kind: "undo", revisionID, subjectVersion: subject.version, conflicts } });
        await tx.update(jobs).set({ progress: { stage: "review", result: { conflicts, version: subject.version } } }).where(eq(jobs.id, job.id));
        await invalidate(tx, userId, "decisions", subjectID, subject.version); return;
      }
      const result = await writeRevision(tx, userId, subject, operationID, before, [...map.values()], "undo", "Undid import", revisionID);
      await tx.update(jobs).set({ progress: { stage: "completed", result } }).where(eq(jobs.id, job.id));
    });
  }
}
