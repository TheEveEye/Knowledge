import { randomUUID } from "node:crypto";
import { z } from "zod";
import { and, asc, desc, eq, gt, inArray, ne, sql } from "drizzle-orm";
import type { AISelection, ImportDraft, ImportDraftSummary, ImportEntryChange, JSONObject, JSONValue, LibraryEntity, Page, SourcePassage } from "@knowledge/contracts";
import type { Database } from "./database.js";
import { AIService } from "./ai.js";
import { DomainError, canonical, expected, invalidate, jsonArray, jsonObject, mutation, normalizeName, ownedSubject, requireValue, stringValue } from "./core.js";
import { revisionSnapshot, snapshot, validateGraph, writeRevision } from "./library.js";
import { JobQueue, type ClaimedJob } from "./jobs.js";
import { imports, jobs, operations, passages, pendingDecisions, preferences, sources } from "./schema.js";
import { removeUnusedImportSource } from "./source-lifecycle.js";
import { policies } from "./policies.js";
import { semanticUpdates } from "./semantic.js";
import { asJSON, connectionKinds, extractionSchema, factKinds, reconciliationBatchSchema, reconciliationSchema, selectionSchema, structured, topicAssignmentBatchSchema, topicOutlineSchema, type Extraction } from "./structured.js";
import { batchContext, batchPlan, extractionProgress, plannedBatches, sourceBatches, streamedConcepts } from "./import-batches.js";
import { repairPendingImportSource } from "./import-source-repair.js";
import { FileStore } from "./files.js";
import { affectedEntries, inferenceInput, sourceReviewBatch, type ReviewPassage, type SourceReviewIssue, type SourceReviewVerdict } from "./import-source-review.js";

export interface DraftEntry { record: LibraryEntity; selected: boolean; reviewReason: string | null; mergeTargetID: string | null; acceptMerge: boolean; original: JSONObject; mergeDecisionLocked?: boolean }
export interface DraftState { entries: DraftEntry[]; coverage: JSONValue[]; updates: JSONValue[]; reviewNotes: string[]; reviewedPassageIDs?: string[]; existingFactReviews?: JSONValue[] }
const draftJSON = (draft: DraftState) => asJSON(draft) as JSONObject;
// Worker checkpoints never belong in a client response.
const importDisplayColumns = { id: imports.id, subjectId: imports.subjectId, sourceId: imports.sourceId, baseRevisionId: imports.baseRevisionId,
  version: imports.version, status: imports.status, draft: sql<JSONObject>`CASE WHEN ${imports.status} = 'saved' THEN '{}'::jsonb ELSE ${imports.draft} END`,
  selection: imports.selection, createdAt: imports.createdAt, updatedAt: imports.updatedAt };
export const importDTO = (row: Pick<typeof imports.$inferSelect, keyof typeof importDisplayColumns>): ImportDraft => ({ id: row.id, subjectID: row.subjectId, sourceID: row.sourceId, baseRevisionID: row.baseRevisionId, version: row.version, status: row.status as ImportDraft["status"], draft: row.status === "saved" ? {} : row.draft, selection: row.selection, createdAt: row.createdAt.toISOString(), updatedAt: row.updatedAt.toISOString() });
const entry = (subjectID: string, kind: LibraryEntity["kind"], id: string, fields: JSONObject, reviewReason: string | null = null): DraftEntry => ({ record: { id, subjectID, kind, fields, protectedFields: [], isRetired: false, redirectID: null }, selected: !reviewReason, reviewReason, mergeTargetID: null, acceptMerge: false, original: structuredClone(fields) });
function unique(ids: string[], label: string) { if (new Set(ids).size !== ids.length) throw new DomainError("INVALID_EXTRACTION", `Duplicate ${label} IDs.`); }
// Reconciliation/review can exclude a prerequisite after extraction selected its
// dependents. Preserve that exclusion and cascade it through facts and connections.
function excludeUnavailableDependents(draft: DraftState, saved: LibraryEntity[]): boolean {
  const available = new Map(saved.filter(r => !r.isRetired).map(r => [r.id, r.kind]));
  const entries = new Map(draft.entries.map(e => [e.record.id, e]));
  const has = (id: JSONValue | undefined, kind: LibraryEntity["kind"]) => {
    if (typeof id !== "string") return false;
    const incoming = entries.get(id);
    return incoming ? incoming.selected && incoming.record.kind === kind : available.get(id) === kind;
  };
  let changed = false, pending = true;
  while (pending) {
    pending = false;
    for (const e of draft.entries) {
      if (!e.selected) continue;
      const { kind, fields } = e.record;
      const unavailable = (kind === "fact" || kind === "placement") ? !has(fields.conceptID, "concept")
        : kind === "connection" && (!has(fields.fromConceptID, "concept") || !has(fields.toConceptID, "concept") || jsonArray(fields.supportingFactIDs).some(id => !has(id, "fact")));
      if (unavailable) { e.selected = false; changed = true; pending = true; }
    }
  }
  if (changed) {
    const note = "Entries requiring excluded or unavailable concepts or supporting facts were excluded. Review the selection before saving.";
    if (!draft.reviewNotes.includes(note)) draft.reviewNotes.push(note);
  }
  return changed;
}
function reconciliationCoverage(value: z.infer<typeof reconciliationSchema>, conceptIDs: string[]) {
  const received = value.decisions.map(d => d.conceptID), required = new Set(conceptIDs);
  const missing = conceptIDs.filter(id => !received.includes(id)), unexpected = received.filter(id => !required.has(id));
  if (missing.length || unexpected.length || new Set(received).size !== received.length) {
    throw new DomainError("INVALID_RECONCILIATION", `Return exactly one decisions array entry per batch concept, using its record.id as conceptID. Missing IDs: ${missing.join(", ") || "none"}. Unexpected IDs: ${unexpected.join(", ") || "none"}. Remove duplicate decisions; use mergeWithID=null for concepts kept separate.`);
  }
}
function reconciliationReferences(value: z.infer<typeof reconciliationSchema>, batch: DraftEntry[], current: LibraryEntity[], draft: DraftEntry[]) {
  reconciliationCoverage(value, batch.map(e => e.record.id));
  // Batch concepts are supplied material too. A canonical identity can be in this
  // same batch, elsewhere in the selected draft, or in the current owned subject.
  const available = new Set([...current.filter(r => r.kind === "concept" && !r.isRetired).map(r => r.id),
    ...draft.filter(e => e.selected && e.record.kind === "concept" && !e.record.isRetired).map(e => e.record.id)]);
  const merges = new Map(draft.filter(e => e.selected && e.record.kind === "concept" && e.acceptMerge && e.mergeTargetID)
    .map(e => [e.record.id, e.mergeTargetID!]));
  // Earlier batches may already have made this proposed target an alias of the
  // current concept. Resolve accepted aliases before overlaying new decisions;
  // merging back into that alias means retaining the canonical concept, not a cycle.
  for (const d of value.decisions) {
    if (!d.mergeWithID || d.mergeWithID === d.conceptID) continue;
    let target = d.mergeWithID;
    const seen = new Set<string>();
    while (merges.has(target)) {
      if (seen.has(target)) throw new DomainError("INVALID_MERGE", "Previously accepted merge decisions contain a cycle.");
      seen.add(target); target = merges.get(target)!;
    }
    d.mergeWithID = target === d.conceptID ? null : target;
  }
  for (const d of value.decisions) {
    if (d.mergeWithID === d.conceptID) throw new DomainError("INVALID_MERGE", `Concept ${d.conceptID} cannot merge into itself. Use mergeWithID=null for a canonical concept kept separate.`);
    if (d.mergeWithID && !available.has(d.mergeWithID)) throw new DomainError("INVALID_MERGE", `Merge target ${d.mergeWithID} is unavailable. Use a supplied live concept from this subject or the selected draft, including this batch, or use mergeWithID=null.`);
    if (d.mergeWithID && !d.reviewReason) merges.set(d.conceptID, d.mergeWithID); else merges.delete(d.conceptID);
  }
  for (const d of value.decisions) {
    const visited = new Set<string>(); let id = d.conceptID;
    while (merges.has(id)) {
      if (visited.has(id)) throw new DomainError("INVALID_MERGE", `Merge decisions form a cycle involving ${[...visited].join(", ")}. Choose one canonical concept with mergeWithID=null and point the other equivalent concepts directly to it.`);
      visited.add(id); id = merges.get(id)!;
      if (!available.has(id)) throw new DomainError("INVALID_MERGE", `Merge chain for ${d.conceptID} ends at unavailable material. Keep it separate or choose a supplied live canonical concept.`);
    }
  }
}
function convertExtraction(value: Extraction, subjectID: string, sourceID: string, required: SourcePassage[], context: SourcePassage[]): DraftState {
  unique(value.concepts.map(c => c.id), "concept"); unique(value.facts.map(c => c.id), "fact"); unique(value.connections.map(c => c.id), "connection"); unique(value.coverage.map(c => c.segmentID), "coverage");
  if (canonical(value.coverage.map(c => c.segmentID).sort()) !== canonical(required.map(c => c.id).sort())) throw new DomainError("INVALID_EXTRACTION", "Some source passages were skipped or counted twice.");
  const concepts = new Map(value.concepts.map(c => [c.id, randomUUID()])), facts = new Map(value.facts.map(c => [c.id, randomUUID()]));
  const segments = new Map(context.map(p => [p.id, p.text])), cited = new Set<string>();
  const normalize = (s: string) => s.normalize("NFKC").replace(/\u00ad/g, "").replace(/\s+/g, " ").trim();
  function evidence(values: { segmentID: string; quote: string }[]): JSONValue[] {
    return values.map(e => { const original = segments.get(e.segmentID); if (!original || !normalize(e.quote) || !normalize(original).includes(normalize(e.quote))) throw new DomainError("INVALID_EVIDENCE", "An evidence quotation is not present in the original passage."); cited.add(e.segmentID); return { sourceID, ...e }; });
  }
  const entries: DraftEntry[] = value.concepts.map(c => entry(subjectID, "concept", concepts.get(c.id)!, { name: c.name, aliases: c.aliases, explanation: c.explanation, evidence: evidence(c.evidence), sourceIDs: [sourceID], wordings: [{ sourceID, original: { name: c.name, aliases: c.aliases, explanation: c.explanation }, edited: null }] }, c.reviewReason));
  for (const fact of value.facts) {
    const conceptID = concepts.get(fact.conceptID); if (!conceptID) throw new DomainError("INVALID_EXTRACTION", "A fact references an unknown concept.");
    if (!fact.evidence.some(e => required.some(p => p.id === e.segmentID))) throw new DomainError("INVALID_EXTRACTION", "A fact does not cite a required passage.");
    entries.push(entry(subjectID, "fact", facts.get(fact.id)!, { conceptID, sourceID, statement: fact.statement, kind: fact.kind, qualifications: fact.qualifications, evidence: evidence(fact.evidence), original: { statement: fact.statement, kind: fact.kind, qualifications: fact.qualifications } }, fact.reviewReason));
  }
  for (const c of value.connections) {
    const from = concepts.get(c.fromConceptID), to = concepts.get(c.toConceptID);
    if (!from || !to || from === to || c.supportingFactIDs.some(id => !facts.has(id))) throw new DomainError("INVALID_EXTRACTION", "A connection has invalid endpoints or supporting facts.");
    const support: string[] = c.supportingFactIDs.map(id => facts.get(id)!);
    const refs = entries.filter(e => support.includes(e.record.id)).flatMap(e => jsonArray(e.record.fields.evidence));
    entries.push(entry(subjectID, "connection", randomUUID(), { fromConceptID: from, toConceptID: to, sourceID, kind: c.kind, explanation: c.explanation, supportingFactIDs: support, evidence: refs, isInferred: false, original: { kind: c.kind, explanation: c.explanation } }, c.reviewReason));
  }
  const coverage = value.coverage.map(c => c.disposition === "extracted" && !cited.has(c.segmentID) ? { ...c, disposition: "uncertain", reason: "No saved entry cites this passage." } : c);
  return { entries, coverage: asJSON(coverage) as JSONValue[], updates: [], reviewNotes: [] };
}
function state(value: JSONObject): DraftState {
  const entries = jsonArray(value.entries).map(raw => {
    const e = jsonObject(raw); return { record: jsonObject(e.record) as unknown as LibraryEntity, selected: e.selected === true, reviewReason: typeof e.reviewReason === "string" ? e.reviewReason : null,
      mergeTargetID: typeof e.mergeTargetID === "string" ? e.mergeTargetID : null, acceptMerge: e.acceptMerge === true, original: jsonObject(e.original), mergeDecisionLocked: e.mergeDecisionLocked === true };
  });
  return { entries, existingFactReviews: jsonArray(value.existingFactReviews), coverage: jsonArray(value.coverage), updates: jsonArray(value.updates), reviewNotes: jsonArray(value.reviewNotes).filter((s): s is string => typeof s === "string"), reviewedPassageIDs: jsonArray(value.reviewedPassageIDs).filter((s): s is string => typeof s === "string") };
}
function retainFactReviews(draft: DraftState, reviews: { factID: string; reason: string }[], current: LibraryEntity[]): boolean {
  let added = false;
  for (const review of reviews) {
    const incoming = draft.entries.find(e => e.record.kind === "fact" && e.record.id === review.factID);
    if (incoming) {
      if (!incoming.reviewReason) { incoming.reviewReason = review.reason; incoming.selected = false; added = true; }
    } else if (current.some(e => e.kind === "fact" && e.id === review.factID && !e.isRetired)) {
      draft.existingFactReviews ??= [];
      if (!draft.existingFactReviews.some(raw => jsonObject(raw).factID === review.factID)) {
        draft.existingFactReviews.push({ factID: review.factID, reason: review.reason, reviewed: false }); added = true;
      }
    }
  }
  return added;
}
export class ImportService {
  constructor(readonly db: Database, readonly ai: AIService, readonly queue: JobQueue) {}
  async get(userId: string, id: string) { return requireValue((await this.db.select().from(imports).where(and(eq(imports.userId, userId), eq(imports.id, id))))[0]); }
  async display(userId: string, id: string) { return importDTO(requireValue((await this.db.select(importDisplayColumns).from(imports).where(and(eq(imports.userId, userId), eq(imports.id, id))))[0])); }
  async list(userId: string, subjectID: string, cursor?: string, limit = 50): Promise<Page<ImportDraft>> {
    await ownedSubject(this.db, userId, subjectID);
    const rows = await this.db.select(importDisplayColumns).from(imports).where(and(eq(imports.userId, userId), eq(imports.subjectId, subjectID), cursor ? gt(imports.id, cursor) : undefined)).orderBy(asc(imports.id)).limit(limit + 1);
    return { items: rows.slice(0, limit).map(importDTO), nextCursor: rows.length > limit ? rows[limit - 1]!.id : null };
  }
  async allDrafts(userId: string, cursor?: string, limit = 50): Promise<Page<ImportDraftSummary>> {
    const rows = await this.db.select({ draft: { id: imports.id, subjectId: imports.subjectId, sourceId: imports.sourceId, version: imports.version, status: imports.status, updatedAt: imports.updatedAt }, title: sources.title }).from(imports)
      .innerJoin(sources, and(eq(sources.userId, imports.userId), eq(sources.subjectId, imports.subjectId), eq(sources.id, imports.sourceId)))
      .where(and(eq(imports.userId, userId), ne(imports.status, "saved"), cursor ? gt(imports.id, cursor) : undefined)).orderBy(asc(imports.id)).limit(limit + 1);
    const page = rows.slice(0, limit), ids = page.map(r => r.draft.id);
    const work = ids.length ? await this.db.select({ importId: jobs.importId, status: jobs.status, progress: jobs.progress }).from(jobs).where(and(eq(jobs.userId, userId), inArray(jobs.importId, ids))).orderBy(desc(jobs.updatedAt)) : [];
    return { items: page.map(({ draft, title }) => {
      const job = work.find(j => j.importId === draft.id && !["completed", "cancelled"].includes(j.status));
      return { id: draft.id, subjectID: draft.subjectId, sourceID: draft.sourceId, version: draft.version, status: draft.status, updatedAt: draft.updatedAt.toISOString(), sourceTitle: title,
        processing: !!job && ["queued", "running"].includes(job.status), jobStatus: job?.status as ImportDraftSummary["jobStatus"] ?? null, activity: job ? stringValue(job.progress.stage) || job.status : draft.status };
    }), nextCursor: rows.length > limit ? rows[limit - 1]!.draft.id : null };
  }
  async create(userId: string, subjectID: string, sourceID: string, selection: AISelection, operationID: string) {
    // Older development uploads can be repaired only while all their passage references are unused.
    const source = await this.db.select({ id: sources.id }).from(sources).where(and(eq(sources.userId, userId), eq(sources.subjectId, subjectID), eq(sources.id, sourceID)));
    requireValue(source[0]);
    await repairPendingImportSource(this.db, new FileStore(), userId, sourceID);
    return mutation(this.db, userId, operationID, { action: "createImport", subjectID, sourceID, selection }, async tx => {
      const subject = await ownedSubject(tx, userId, subjectID, true);
      const source = requireValue((await tx.select().from(sources).where(and(eq(sources.userId, userId), eq(sources.subjectId, subjectID), eq(sources.id, sourceID))))[0]);
      if (source.status !== "ready") throw new DomainError("SOURCE_NOT_READY", source.error ?? "Source preparation has not completed.", 409);
      const segments = (await tx.select().from(passages).where(and(eq(passages.userId, userId), eq(passages.sourceId, sourceID))).orderBy(asc(passages.ordinal))).map(p => ({ id: p.id, page: p.page, section: p.section, text: p.text }));
      const chunks = sourceBatches(segments), checkpoint = { batchPlan: batchPlan(chunks) };
      if (!chunks.length) throw new DomainError("EMPTY_SOURCE", "This source has no readable passages.");
      const row = requireValue((await tx.insert(imports).values({ userId, subjectId: subjectID, sourceId: sourceID, baseRevisionId: subject.revisionId, selection, aiConnectionId: selection.connectionID }).returning())[0]);
      const job = requireValue((await tx.insert(jobs).values({ userId, subjectId: subjectID, importId: row.id, kind: "import", input: { importID: row.id, inputVersion: row.version }, checkpoint, progress: extractionProgress(segments, chunks, checkpoint), selection, aiConnectionId: selection.connectionID }).returning())[0]);
      await invalidate(tx, userId, "imports", subjectID, row.version); return { importID: row.id, jobID: job.id };
    });
  }
  async recheck(userId: string, id: string, operationID: string, version: number, selection: AISelection) {
    return mutation(this.db, userId, operationID, { action: "recheckImport", id, version, selection }, async tx => {
      const initial = await this.get(userId, id); await ownedSubject(tx, userId, initial.subjectId, true);
      const row = requireValue((await tx.select().from(imports).where(and(eq(imports.userId, userId), eq(imports.id, id))).for("update"))[0]); expected(row.version, version);
      if (row.status !== "review") throw new DomainError("DRAFT_UNAVAILABLE", "Finish processing before rechecking this import.", 409);
      const active = await tx.select().from(jobs).where(and(eq(jobs.userId, userId), eq(jobs.importId, id), inArray(jobs.status, ["queued", "running", "paused", "blocked"])));
      if (active.length) throw new DomainError("JOB_ACTIVE", "Resume or cancel the existing work before starting a source recheck.", 409);
      const job = requireValue((await tx.insert(jobs).values({ userId, subjectId: row.subjectId, importId: id, kind: "import", input: { inputVersion: version + 1, recheck: true }, progress: { stage: "reviewing", completed: 0 }, selection, aiConnectionId: selection.connectionID }).returning())[0]);
      await tx.update(imports).set({ status: "processing", version: version + 1, selection, aiConnectionId: selection.connectionID, updatedAt: new Date() }).where(and(eq(imports.userId, userId), eq(imports.id, id)));
      await invalidate(tx, userId, "imports", row.subjectId, version + 1); return { version: version + 1, jobID: job.id };
    });
  }
  async acknowledgePassage(userId: string, id: string, operationID: string, version: number, passageID: string, reviewed: boolean) {
    return mutation(this.db, userId, operationID, { action: "reviewImportPassage", id, version, passageID, reviewed }, async tx => {
      const initial = await this.get(userId, id); await ownedSubject(tx, userId, initial.subjectId, true);
      const row = requireValue((await tx.select().from(imports).where(and(eq(imports.userId, userId), eq(imports.id, id))).for("update"))[0]); expected(row.version, version);
      if (row.status !== "review") throw new DomainError("DRAFT_UNAVAILABLE", "Wait for this import to be ready for review.", 409);
      const draft = state(row.draft);
      if (!draft.coverage.some(value => jsonObject(value).segmentID === passageID && jsonObject(value).disposition === "uncertain")) throw new DomainError("PASSAGE_UNAVAILABLE", "Choose an uncertain passage from this import.");
      const ids = new Set(draft.reviewedPassageIDs ?? []); if (reviewed) ids.add(passageID); else ids.delete(passageID); draft.reviewedPassageIDs = [...ids].sort();
      await tx.update(imports).set({ draft: draftJSON(draft), version: version + 1, updatedAt: new Date() }).where(and(eq(imports.userId, userId), eq(imports.id, id)));
      await invalidate(tx, userId, "imports", row.subjectId, version + 1); return { version: version + 1 };
    });
  }
  async acknowledgeExistingFact(userId: string, id: string, operationID: string, version: number, factID: string, reviewed: boolean) {
    return mutation(this.db, userId, operationID, { action: "reviewExistingFact", id, version, factID, reviewed }, async tx => {
      const initial = await this.get(userId, id); await ownedSubject(tx, userId, initial.subjectId, true);
      const row = requireValue((await tx.select().from(imports).where(and(eq(imports.userId, userId), eq(imports.id, id))).for("update"))[0]); expected(row.version, version);
      if (row.status !== "review") throw new DomainError("DRAFT_UNAVAILABLE", "Wait for this import to be ready for review.", 409);
      const draft = state(row.draft), reviews = draft.existingFactReviews ?? [];
      if (!reviews.some(raw => jsonObject(raw).factID === factID)) throw new DomainError("NOT_FOUND", "This fact has no warning in this import.", 404);
      draft.existingFactReviews = reviews.map(raw => jsonObject(raw).factID === factID ? { ...jsonObject(raw), reviewed } : raw);
      await tx.update(imports).set({ draft: draftJSON(draft), version: version + 1, updatedAt: new Date() }).where(eq(imports.id, id));
      await invalidate(tx, userId, "imports", row.subjectId, version + 1); return { version: version + 1 };
    });
  }
  async edit(userId: string, id: string, operationID: string, version: number, changes: ImportEntryChange[]) {
    return mutation(this.db, userId, operationID, { action: "editDraft", id, version, changes }, async tx => {
      const initial = await this.get(userId, id); await ownedSubject(tx, userId, initial.subjectId, true);
      const row = requireValue((await tx.select().from(imports).where(and(eq(imports.userId, userId), eq(imports.id, id))).for("update"))[0]); expected(row.version, version);
      if (row.status !== "review") throw new DomainError("DRAFT_UNAVAILABLE", "This import is not available for review.", 409);
      const draft = state(row.draft);
      for (const change of changes) {
        const e = requireValue(draft.entries.find(e => e.record.id === change.id));
        if (change.fields) {
          const allowed: Record<string, string[]> = { concept: ["name", "aliases", "explanation"], fact: ["statement", "kind", "qualifications"], connection: ["kind", "explanation"], topic: ["name"] };
          for (const [field, value] of Object.entries(change.fields)) {
            if (!allowed[e.record.kind]?.includes(field)) throw new DomainError("INVALID_EDIT", "This draft field cannot be edited.");
            const validator = field === "aliases" ? z.array(z.string().trim().min(1).max(240)).max(100)
              : field === "kind" ? z.enum(e.record.kind === "fact" ? factKinds : connectionKinds)
              : z.string().max(field === "name" ? 240 : 30_000);
            e.record.fields[field] = validator.parse(value);
            e.record.protectedFields = [...new Set([...e.record.protectedFields, field])];
          }
        }
        if (change.name !== undefined) { if (!["concept", "topic"].includes(e.record.kind) || !change.name.trim()) throw new DomainError("INVALID_EDIT", "Give this entry a name."); e.record.fields.name = change.name.trim(); e.record.protectedFields = [...new Set([...e.record.protectedFields, "name"])]; }
        if (change.acceptMerge !== undefined) { e.acceptMerge = change.acceptMerge; e.mergeDecisionLocked = true; }
        if (change.resolutionAction && e.record.fields.resolutionSuggestion) {
          const suggestion = jsonObject(e.record.fields.resolutionSuggestion);
          if (change.resolutionAction === "apply" && suggestion.status === "pending") { suggestion.previousName = e.record.fields.name ?? ""; if (typeof suggestion.suggestedName === "string") e.record.fields.name = suggestion.suggestedName; suggestion.status = "applied"; e.record.protectedFields = [...new Set([...e.record.protectedFields, "name"])]; }
          if (change.resolutionAction === "undo" && suggestion.status === "applied") { if (e.record.fields.name === suggestion.suggestedName) e.record.fields.name = suggestion.previousName ?? e.record.fields.name ?? ""; suggestion.status = "pending"; }
          if (change.resolutionAction === "dismiss") suggestion.status = "dismissed";
          if (change.resolutionAction === "restore" && suggestion.status === "dismissed") suggestion.status = "pending";
        }
        if (change.selected !== undefined) e.selected = change.selected;
      }
      // Selecting a dependent entry requires explicit selection of its prerequisites.
      const selected = new Set([...draft.entries.filter(e => e.selected).map(e => e.record.id), ...(await snapshot(tx, userId, row.subjectId)).filter(e => !e.isRetired).map(e => e.id)]);
      for (const e of draft.entries) if (e.selected && e.record.kind === "fact" && !selected.has(stringValue(e.record.fields.conceptID))) throw new DomainError("INVALID_SELECTION", "Select the concept before selecting its fact.");
      for (const e of draft.entries) if (e.selected && e.record.kind === "connection" && [e.record.fields.fromConceptID, e.record.fields.toConceptID, ...jsonArray(e.record.fields.supportingFactIDs)].some(id => typeof id !== "string" || !selected.has(id))) throw new DomainError("INVALID_SELECTION", "Select a connection's concepts and supporting facts first.");
      await tx.update(imports).set({ draft: draftJSON(draft), version: version + 1, updatedAt: new Date() }).where(eq(imports.id, id));
      await invalidate(tx, userId, "imports", row.subjectId, version + 1); return { version: version + 1 };
    });
  }
  async save(userId: string, id: string, operationID: string, version: number, choices: JSONObject = {}, subjectVersion: number | null = null) {
    return mutation(this.db, userId, operationID, { action: "saveImport", id, version, choices, subjectVersion }, async tx => {
      const initial = await this.get(userId, id), subject = await ownedSubject(tx, userId, initial.subjectId, true);
      if (Object.keys(choices).length) {
        if (subjectVersion === null) throw new DomainError("VERSION_REQUIRED", "Refresh the conflict review before applying these choices.", 409);
        expected(subject.version, subjectVersion);
      }
      const row = requireValue((await tx.select().from(imports).where(and(eq(imports.userId, userId), eq(imports.id, id))).for("update"))[0]); expected(row.version, version);
      if (row.status === "saved") return { saved: true };
      if (row.status !== "review") throw new DomainError("DRAFT_UNAVAILABLE", "Finish processing before saving.", 409);
      const active = (await tx.select().from(jobs).where(and(eq(jobs.userId, userId), eq(jobs.importId, id), eq(jobs.kind, "prepareCommit")))).find(j => ["queued", "running", "paused", "blocked"].includes(j.status));
      if (active) throw new DomainError("SAVE_PENDING", "Resume or cancel the pending save before saving again.", 409);
      const draft = state(row.draft);
      if (excludeUnavailableDependents(draft, await snapshot(tx, userId, row.subjectId))) {
        await tx.update(imports).set({ draft: draftJSON(draft), version: row.version + 1, updatedAt: new Date() }).where(eq(imports.id, id));
        await invalidate(tx, userId, "imports", row.subjectId, row.version + 1);
        return { requiresReview: true, version: row.version + 1 };
      }
      for (const entry of state(row.draft).entries.filter(e => e.selected)) {
        const fields = entry.record.fields, kind = entry.record.kind;
        if ((kind === "concept" || kind === "topic") && !stringValue(fields.name).trim()) throw new DomainError("INVALID_EDIT", "Give each included concept and topic a name before saving.");
        if (kind === "concept" && !stringValue(fields.explanation).trim() || kind === "fact" && !stringValue(fields.statement).trim() || kind === "connection" && !stringValue(fields.explanation).trim()) throw new DomainError("INVALID_EDIT", "Complete the wording of each included entry before saving, or exclude that entry.");
      }
      if (!state(row.draft).entries.some(e => e.selected && ["concept", "fact", "connection"].includes(e.record.kind))) throw new DomainError("EMPTY_SELECTION", "Select study material before saving this import.");
      const job = requireValue((await tx.insert(jobs).values({ userId, subjectId: row.subjectId, importId: id, kind: "prepareCommit", input: { importID: id, operationID, inputVersion: version, choices, subjectVersion }, progress: { stage: "preparingCommit", completed: 0 }, selection: row.selection, aiConnectionId: row.aiConnectionId }).returning())[0]);
      await invalidate(tx, userId, "jobs", row.subjectId, 1); return { jobID: job.id };
    });
  }
  async changeDraft(userId: string, id: string, operationID: string, version: number, changes: { operation: "include" | "exclude" | "rename_concept" | "rename_topic" | "move_concept"; entryID: string; value: string | null; topicID: string | null }[]) {
    return mutation(this.db, userId, operationID, { action: "draftChanges", id, version, changes }, async tx => {
      const initial = await this.get(userId, id); await ownedSubject(tx, userId, initial.subjectId, true);
      const row = requireValue((await tx.select().from(imports).where(and(eq(imports.userId, userId), eq(imports.id, id))).for("update"))[0]); expected(row.version, version);
      if (row.status !== "review") throw new DomainError("DRAFT_UNAVAILABLE", "Wait for this import to be ready for review.", 409);
      const draft = state(row.draft), saved = await snapshot(tx, userId, row.subjectId);
      for (const change of changes) {
        const target = requireValue(draft.entries.find(e => e.record.id === change.entryID));
        if (change.operation === "include" || change.operation === "exclude") {
          const include = change.operation === "include", pending = [target.record.id], visited = new Set<string>();
          while (pending.length) {
            const next = pending.pop()!; if (visited.has(next)) continue; visited.add(next);
            const entry = draft.entries.find(e => e.record.id === next); if (!entry) { if (include && !saved.some(e => e.id === next && !e.isRetired)) throw new DomainError("INVALID_SELECTION", "A required entry is unavailable."); continue; }
            if (include && !entry.selected && entry.reviewReason) throw new DomainError("REVIEW_REQUIRED", "This entry or a required dependency has a source review flag. Include it manually after checking its evidence.");
            entry.selected = include;
            if (include) pending.push(...[entry.record.fields.conceptID, entry.record.fields.fromConceptID, entry.record.fields.toConceptID, ...jsonArray(entry.record.fields.supportingFactIDs)].filter((v): v is string => typeof v === "string"));
            else for (const dependent of draft.entries) if ([dependent.record.fields.conceptID, dependent.record.fields.fromConceptID, dependent.record.fields.toConceptID, ...jsonArray(dependent.record.fields.supportingFactIDs)].includes(next)) pending.push(dependent.record.id);
          }
        } else if (change.operation === "rename_concept" || change.operation === "rename_topic") {
          if (target.record.kind !== (change.operation === "rename_concept" ? "concept" : "topic") || !change.value?.trim() || change.value.length > 240) throw new DomainError("INVALID_EDIT", "Choose a draft concept or new topic and a nonempty name.");
          target.record.fields.name = change.value.trim(); target.record.protectedFields = [...new Set([...target.record.protectedFields, "name"])];
        } else {
          if (target.record.kind !== "concept" || target.acceptMerge) throw new DomainError("INVALID_PLACEMENT", "Only new unmerged concepts can be moved in this draft.");
          if (change.topicID && ![...saved, ...draft.entries.filter(e => e.selected).map(e => e.record)].some(e => e.id === change.topicID && e.kind === "topic" && !e.isRetired)) throw new DomainError("INVALID_PLACEMENT", "Choose a topic in this subject.");
          let placement = draft.entries.find(e => e.record.kind === "placement" && e.record.fields.conceptID === target.record.id);
          if (!placement) { placement = entry(row.subjectId, "placement", randomUUID(), { conceptID: target.record.id, topicID: change.topicID, isLocked: true, reason: "User-directed draft placement" }); draft.entries.push(placement); }
          placement.record.fields.topicID = change.topicID; placement.record.fields.isLocked = true; placement.record.protectedFields = ["topicID", "isLocked"]; placement.selected = target.selected;
        }
      }
      if (canonical(draftJSON(draft)) === canonical(row.draft)) return { version, undoID: null, summary: "The draft already matches these changes." };
      const undoID = randomUUID();
      await tx.update(imports).set({ draft: draftJSON(draft), checkpoint: { ...row.checkpoint, draftEditUndo: { id: undoID, before: row.draft, appliedVersion: version + 1 } }, version: version + 1, updatedAt: new Date() }).where(eq(imports.id, id));
      await invalidate(tx, userId, "imports", row.subjectId, version + 1); return { version: version + 1, undoID, summary: "Updated the draft. Saved library records are unchanged." };
    });
  }
  async undoDraftChange(userId: string, id: string, changeID: string, operationID: string, version: number) {
    return mutation(this.db, userId, operationID, { action: "undoDraftChange", id, changeID, version }, async tx => {
      const initial = await this.get(userId, id); await ownedSubject(tx, userId, initial.subjectId, true);
      const row = requireValue((await tx.select().from(imports).where(and(eq(imports.userId, userId), eq(imports.id, id))).for("update"))[0]); expected(row.version, version);
      const undo = jsonObject(row.checkpoint.draftEditUndo ?? {});
      if (row.status !== "review" || undo.id !== changeID || Number(undo.appliedVersion) !== version) throw new DomainError("UNDO_UNAVAILABLE", "Later draft changes prevent undoing this batch.", 409);
      await tx.update(imports).set({ draft: jsonObject(undo.before), checkpoint: { ...row.checkpoint, draftEditUndo: null }, version: version + 1, updatedAt: new Date() }).where(eq(imports.id, id));
      await invalidate(tx, userId, "imports", row.subjectId, version + 1); return { version: version + 1 };
    });
  }
  async delete(userId: string, id: string, operationID: string, version: number) {
    return mutation(this.db, userId, operationID, { action: "deleteImport", id, version }, async tx => {
      const row = await this.get(userId, id); await ownedSubject(tx, userId, row.subjectId, true); expected(row.version, version);
      if (row.status === "saved") throw new DomainError("IMPORT_SAVED", "Use History to undo a saved import.", 409);
      await tx.delete(pendingDecisions).where(and(eq(pendingDecisions.userId, userId), eq(pendingDecisions.importId, id)));
      await tx.delete(jobs).where(and(eq(jobs.userId, userId), eq(jobs.importId, id)));
      await tx.delete(imports).where(and(eq(imports.userId, userId), eq(imports.id, id)));
      await tx.update(operations).set({ response: { resourceDeleted: true }, leaseId: null, leaseExpiresAt: null })
        .where(and(eq(operations.userId, userId), sql`${operations.response}->>'importID'=${id}`));
      const sourceDeleted = await removeUnusedImportSource(tx, userId, row.subjectId, row.sourceId);
      await invalidate(tx, userId, "imports", row.subjectId, version + 1); return { deleted: true, sourceDeleted };
    });
  }
  async process(job: ClaimedJob, signal: AbortSignal) {
    const row = await this.get(job.userId, requireValue(job.importId)), selection = requireValue(job.selection);
    if (row.status === "saved") { await this.queue.complete(job, async () => {}); return; }
    const allPassages = (await this.db.select().from(passages).where(and(eq(passages.userId, job.userId), eq(passages.sourceId, row.sourceId))).orderBy(asc(passages.ordinal))).map(p => ({ id: p.id, page: p.page, section: p.section, text: p.text }));
    if (job.input.recheck === true) {
      const checkpoint = structuredClone(job.checkpoint), reviewed = await this.reviewSource(job, row, state(row.draft), allPassages, signal, checkpoint);
      await this.queue.complete(job, async tx => {
        const latest = requireValue((await tx.select().from(imports).where(and(eq(imports.userId, job.userId), eq(imports.id, row.id))).for("update"))[0]); expected(latest.version, Number(job.input.inputVersion));
        await tx.update(imports).set({ draft: draftJSON(reviewed), checkpoint, status: "review", version: latest.version + 1, updatedAt: new Date() }).where(and(eq(imports.userId, job.userId), eq(imports.id, row.id)));
        await invalidate(tx, job.userId, "imports", row.subjectId, latest.version + 1);
      });
      return;
    }
    const checkpoint = structuredClone(job.checkpoint), batches = jsonObject(checkpoint.batches ?? {});
    const chunks = plannedBatches(allPassages, checkpoint);
    if (!chunks.length) throw new DomainError("EMPTY_SOURCE", "This source has no readable passages.");
    checkpoint.batchPlan = batchPlan(chunks);
    const pending = chunks.filter(b => !batches[String(b.index)]), live = new Map<number, JSONObject>();
    for (const batch of pending) live.set(batch.index, { state: "active", activity: "processing", attempt: 1, receivedCharacters: 0, previewConcepts: [] });
    const controller = new AbortController(), extractionSignal = AbortSignal.any([signal, controller.signal]);
    let writes = Promise.resolve(), reportedAt = 0;
    // Network requests run together. Only checkpoint publication is serialized so a later
    // completion cannot replace a newer snapshot or discard another batch's accepted work.
    const publish = (accepted?: { index: number; draft: DraftState }) => {
      const write = writes.then(async () => {
        if (accepted) {
          const nextBatches = { ...batches, [String(accepted.index)]: draftJSON(accepted.draft) };
          const nextCheckpoint = structuredClone({ ...checkpoint, batches: nextBatches }), nextLive = new Map(live);
          nextLive.set(accepted.index, { ...live.get(accepted.index), state: "checked", activity: "saved", previewConcepts: [] });
          await this.queue.checkpoint(job, nextCheckpoint, extractionProgress(allPassages, chunks, nextCheckpoint, nextLive));
          batches[String(accepted.index)] = nextBatches[String(accepted.index)]!; checkpoint.batches = batches;
          live.set(accepted.index, nextLive.get(accepted.index)!);
        } else {
          await this.queue.report(job, extractionProgress(allPassages, chunks, checkpoint, live));
        }
      });
      writes = write.catch(() => {});
      return write;
    };
    await this.queue.checkpoint(job, checkpoint, extractionProgress(allPassages, chunks, checkpoint, live));
    const results = await Promise.allSettled(pending.map(async batch => {
      const i = batch.index;
      try {
        extractionSignal.throwIfAborted();
        const required = batch.required, first = allPassages.findIndex(p => p.id === required[0]!.id);
        let converted: DraftState | null = null, issue = "";
        for (let attempt = 0; attempt < 3; attempt++) {
          converted = null;
          const window = batchContext(batch, allPassages, [4_000, 12_000, 36_000][attempt]!);
          live.set(i, { state: "active", activity: "processing", attempt: attempt + 1, receivedCharacters: 0, previewConcepts: [] });
          if (attempt) await publish();
          let streamed = "", parsedAt = 0;
          try {
            const extracted = await structured(this.ai, job.userId, selection, "extraction", policies.import_extractionInstructions, { requiredSegmentIDs: required.map(p => p.id), segments: asJSON(window), hasEarlierSource: first > 0, hasLaterSource: first + required.length < allPassages.length, previousCoverage: [], validationIssues: [issue] }, extractionSchema, extractionSignal, true, 1, async piece => {
              streamed += piece;
              live.set(i, { ...live.get(i), activity: "receiving", receivedCharacters: streamed.length });
              if (Date.now() - parsedAt >= 2000) {
                parsedAt = Date.now();
                const previewConcepts = streamedConcepts(streamed).map(c => ({ id: stringValue(c.id).slice(0, 200), name: stringValue(c.name).slice(0, 200),
                  segmentIDs: jsonArray(c.evidence).map(e => stringValue(jsonObject(e).segmentID)).filter(id => window.some(p => p.id === id)), checked: false, reviewReason: null }));
                live.set(i, { ...live.get(i), previewConcepts });
              }
              if (Date.now() - reportedAt < 2000) return;
              reportedAt = Date.now();
              await publish();
            });
            live.set(i, { ...live.get(i), activity: "validating" });
            await publish();
            converted = convertExtraction(extracted, row.subjectId, row.sourceId, required, window);
            if (attempt < 2 && extracted.coverage.some(c => c.contextRequest)) { issue = "Resolve the requested source context with the expanded passages."; continue; }
            break;
          }
          catch (error) { if (!(error instanceof DomainError) || !["INVALID_EXTRACTION", "INVALID_EVIDENCE", "INVALID_AI_RESPONSE"].includes(error.code)) throw error; issue = error.message; }
        }
        if (!converted) throw new DomainError("INVALID_EXTRACTION", issue);
        await publish({ index: i, draft: converted });
      } catch (error) {
        live.set(i, { ...live.get(i), state: "failed", error: error instanceof DomainError ? error.message : "This batch was interrupted. Retry to continue." });
        if (error instanceof DomainError && ["AI_UNAUTHORIZED", "AI_LIMIT", "AI_DISCONNECTED", "LEASE_LOST", "NOT_FOUND"].includes(error.code)) controller.abort(error);
        try { await publish(); } catch { /* The original failure remains authoritative if the lease was lost. */ }
        throw error;
      }
    }));
    await writes;
    signal.throwIfAborted();
    const failures = results.filter((result): result is PromiseRejectedResult => result.status === "rejected");
    if (failures.length) throw (failures.find(result => result.reason instanceof DomainError && ["AI_UNAUTHORIZED", "AI_LIMIT", "AI_DISCONNECTED"].includes(result.reason.code)) ?? failures[0])!.reason;
    let draft: DraftState = { entries: [], coverage: [], updates: [], reviewNotes: [] };
    for (let i = 0; i < chunks.length; i++) { const part = state(jsonObject(batches[String(i)])); draft.entries.push(...part.entries); draft.coverage.push(...part.coverage); }
    const current = await revisionSnapshot(this.db, job.userId, row.subjectId, row.baseRevisionId);
    if (checkpoint.reconciled) draft = state(jsonObject(checkpoint.reconciled));
    else {
      if (checkpoint.reconciliationDraft) draft = state(jsonObject(checkpoint.reconciliationDraft));
      // Batch candidates by meaning-bearing context; a name match alone is never an automatic identity merge.
      const concepts = draft.entries.filter(e => e.record.kind === "concept");
      for (let offset = Number(checkpoint.reconciliationOffset ?? 0); offset < concepts.length; offset += 25) {
        const batch = concepts.slice(offset, offset + 25), candidates = [...current.filter(e => e.kind === "concept" && !e.isRetired), ...concepts.filter(e => !batch.includes(e)).map(e => e.record)];
        await this.queue.report(job, { stage: "reconciling", completed: offset, total: concepts.length });
        const decision = await structured(this.ai, job.userId, selection, "reconciliation", policies.import_reconciliationInstructions,
          { batchConcepts: asJSON(batch.map(e => e.record)), candidates: asJSON(candidates), existingMergeDecisions: asJSON(draft.entries.filter(e => e.acceptMerge && e.mergeTargetID).map(e => ({ conceptID: e.record.id, canonicalID: e.mergeTargetID }))), facts: asJSON([...current.filter(e => e.kind === "fact"), ...draft.entries.filter(e => e.record.kind === "fact").map(e => e.record)]), connections: asJSON(current.filter(e => e.kind === "connection")) }, reconciliationBatchSchema(batch.map(e => e.record.id)), signal, true, 3, undefined, value => reconciliationReferences(value, batch, current, draft.entries));
        unique(decision.decisions.map(d => d.conceptID), "reconciliation");
        if (canonical(decision.decisions.map(d => d.conceptID).sort()) !== canonical(batch.map(e => e.record.id).sort())) throw new DomainError("INVALID_RECONCILIATION", "Every supplied concept requires one identity decision.");
        for (const d of decision.decisions) {
          const e = requireValue(batch.find(e => e.record.id === d.conceptID));
          if (d.mergeWithID && ![...current, ...draft.entries.map(e => e.record)].some(c => c.kind === "concept" && c.id === d.mergeWithID && c.id !== e.record.id)) throw new DomainError("INVALID_RECONCILIATION", "An identity decision references an unknown concept.");
          e.mergeTargetID = d.mergeWithID; e.acceptMerge = d.mergeWithID !== null && !d.reviewReason;
          if (d.reviewReason) { e.reviewReason = d.reviewReason; e.selected = false; }
        }
        retainFactReviews(draft, decision.factReviews, current);
        draft.updates.push(...asJSON(decision.updates) as JSONValue[]);
        // Independent source review decides which suggestions can be selected.
        for (const c of decision.connections) {
          const known = [...current, ...draft.entries.map(e => e.record)];
          if (c.fromConceptID === c.toConceptID || !known.some(e => e.kind === "concept" && e.id === c.fromConceptID) || !known.some(e => e.kind === "concept" && e.id === c.toConceptID) || c.supportingFactIDs.some(id => !known.some(e => e.kind === "fact" && e.id === id))) continue;
          const e = entry(row.subjectId, "connection", randomUUID(), { ...c, sourceID: row.sourceId, evidence: known.filter(e => c.supportingFactIDs.includes(e.id)).flatMap(e => jsonArray(e.fields.evidence)), isInferred: true }); e.selected = false; draft.entries.push(e);
        }
        checkpoint.reconciliationDraft = draftJSON(draft); checkpoint.reconciliationOffset = offset + 25;
        await this.queue.checkpoint(job, checkpoint, { stage: "reconciling", completed: Math.min(offset + 25, concepts.length), total: concepts.length });
      }
      checkpoint.reconciled = draftJSON(draft); await this.queue.checkpoint(job, checkpoint, { stage: "organizing" });
    }
    if (checkpoint.reviewed) draft = state(jsonObject(checkpoint.reviewed));
    else {
      draft = await this.reviewSource(job, row, draft, allPassages, signal, checkpoint);
      checkpoint.reviewed = draftJSON(draft); await this.queue.checkpoint(job, checkpoint, { stage: "reviewing" });
    }
    if (checkpoint.named) draft = state(jsonObject(checkpoint.named));
    else {
      draft = await this.suggestNames(job, row, draft, allPassages, signal, checkpoint);
      checkpoint.named = draftJSON(draft); await this.queue.checkpoint(job, checkpoint, { stage: "organizing" });
    }
    if (checkpoint.organized) draft = state(jsonObject(checkpoint.organized));
    else {
      if (checkpoint.organizationDraft) draft = state(jsonObject(checkpoint.organizationDraft));
      const concepts = draft.entries.filter(e => e.record.kind === "concept");
      const existingTopics = current.filter(e => e.kind === "topic" && !e.isRetired);
      if (!checkpoint.organizationDraft) {
        const outline = await structured(this.ai, job.userId, selection, "topic_outline", policies.topics_outlineInstructions, { concepts: asJSON(concepts.map(e => e.record)), topics: asJSON(existingTopics) }, topicOutlineSchema, signal);
        const topicIDs = new Map(outline.topics.map(t => [t.id, randomUUID()]));
        for (const t of outline.topics) draft.entries.push(entry(row.subjectId, "topic", topicIDs.get(t.id)!, { name: t.name, parentID: t.parentTopicID ? topicIDs.get(t.parentTopicID) ?? t.parentTopicID : null, sortOrder: draft.entries.length }));
        draft.updates.push(...asJSON(outline.updates) as JSONValue[]);
        checkpoint.organizationDraft = draftJSON(draft); await this.queue.checkpoint(job, checkpoint, { stage: "organizing", completed: 0, total: concepts.length });
      }
      const topics = [...existingTopics, ...draft.entries.filter(e => e.record.kind === "topic").map(e => e.record)];
      for (let offset = Number(checkpoint.organizationOffset ?? 0); offset < concepts.length; offset += 25) {
        const batch = concepts.slice(offset, offset + 25);
        const assignments = await structured(this.ai, job.userId, selection, "topic_assignments", policies.topics_assignmentInstructions + "\nReturn placements keyed by every supplied concept record.id. Use only supplied topic record.id values, or null for Unsorted.", { concepts: asJSON(batch.map(e => e.record)), topics: asJSON(topics) }, topicAssignmentBatchSchema(batch.map(e => e.record.id), topics.map(t => t.id)), signal);
        unique(assignments.placements.map(p => p.conceptID), "placement");
        if (canonical(assignments.placements.map(p => p.conceptID).sort()) !== canonical(batch.map(e => e.record.id).sort())) throw new DomainError("INVALID_ORGANIZATION", "Every concept requires a placement decision.");
        for (const p of assignments.placements) { if (p.topicID && !topics.some(t => t.id === p.topicID)) throw new DomainError("INVALID_ORGANIZATION", "A placement references an unknown topic."); draft.entries.push(entry(row.subjectId, "placement", randomUUID(), { conceptID: p.conceptID, topicID: p.topicID, isLocked: false, reason: p.reviewReason })); }
        checkpoint.organizationDraft = draftJSON(draft); checkpoint.organizationOffset = offset + 25;
        await this.queue.checkpoint(job, checkpoint, { stage: "organizing", completed: Math.min(offset + 25, concepts.length), total: concepts.length });
      }
      checkpoint.organized = draftJSON(draft); await this.queue.checkpoint(job, checkpoint, { stage: "review" });
    }
    await this.queue.complete(job, async tx => {
      const latest = requireValue((await tx.select().from(imports).where(and(eq(imports.id, row.id), eq(imports.userId, job.userId))).for("update"))[0]); expected(latest.version, Number(job.input.inputVersion));
      excludeUnavailableDependents(draft, await snapshot(tx, job.userId, row.subjectId));
      await tx.update(imports).set({ draft: draftJSON(draft), checkpoint, status: "review", version: row.version + 1, updatedAt: new Date() }).where(eq(imports.id, row.id));
      await invalidate(tx, job.userId, "imports", row.subjectId, row.version + 1);
    });
  }
  async commit(job: ClaimedJob, signal: AbortSignal) {
    const row = await this.get(job.userId, requireValue(job.importId));
    if (row.status === "saved") { await this.queue.complete(job, async () => {}); return; }
    expected(row.version, Number(job.input.inputVersion));
    // Also repair already queued/failed saves before reusing their AI checkpoint.
    const selectionDraft = state(row.draft);
    if (excludeUnavailableDependents(selectionDraft, await snapshot(this.db, job.userId, row.subjectId))) {
      await this.queue.complete(job, async tx => {
        const latest = requireValue((await tx.select().from(imports).where(and(eq(imports.id, row.id), eq(imports.userId, job.userId))).for("update"))[0]); expected(latest.version, row.version);
        await tx.update(imports).set({ draft: draftJSON(selectionDraft), version: latest.version + 1, updatedAt: new Date() }).where(eq(imports.id, row.id));
        await tx.update(jobs).set({ progress: { stage: "review", message: "Selection dependencies were repaired. Review the draft before saving." } }).where(eq(jobs.id, job.id));
        await invalidate(tx, job.userId, "imports", row.subjectId, latest.version + 1);
      });
      return;
    }
    const head = await ownedSubject(this.db, job.userId, row.subjectId), checkpoint = structuredClone(job.checkpoint);
    if (Object.keys(jsonObject(job.input.choices ?? {})).length) expected(head.version, Number(job.input.subjectVersion));
    const resume = checkpoint.commitHeadID === head.revisionId && checkpoint.commitImportVersion === row.version;
    const prepared = resume && checkpoint.commitPrepared ? state(jsonObject(checkpoint.commitPrepared)) : state(row.draft);
    const base = await revisionSnapshot(this.db, job.userId, row.subjectId, row.baseRevisionId), baseByID = new Map(base.map(r => [r.id, r]));
    {
      const current = await snapshot(this.db, job.userId, row.subjectId);
      const batch = prepared.entries.filter(e => e.record.kind === "concept" && e.selected && !e.mergeDecisionLocked);
      if (batch.length) {
        for (let offset = resume ? Number(checkpoint.commitOffset ?? 0) : 0; offset < batch.length; offset += 25) {
          const values = batch.slice(offset, offset + 25);
          const candidates = [...current.filter(r => r.kind === "concept" && !r.isRetired), ...prepared.entries.filter(e => e.record.kind === "concept" && e.selected && !values.includes(e)).map(e => e.record)];
          await this.queue.report(job, { stage: "preparingCommit", completed: offset, total: batch.length });
          const decision = await structured(this.ai, job.userId, requireValue(job.selection), "commit_reconciliation", policies.import_reconciliationInstructions,
            { batchConcepts: asJSON(values.map(e => e.record)), candidates: asJSON(candidates), existingMergeDecisions: asJSON(prepared.entries.filter(e => e.acceptMerge && e.mergeTargetID).map(e => ({ conceptID: e.record.id, canonicalID: e.mergeTargetID }))), facts: asJSON([...current.filter(r => r.kind === "fact"), ...prepared.entries.filter(e => e.record.kind === "fact").map(e => e.record)]), connections: asJSON(current.filter(r => r.kind === "connection")) }, reconciliationBatchSchema(values.map(e => e.record.id)), signal, true, 3, undefined, value => reconciliationReferences(value, values, current, prepared.entries));
          unique(decision.decisions.map(d => d.conceptID), "commit reconciliation");
          if (canonical(decision.decisions.map(d => d.conceptID).sort()) !== canonical(values.map(e => e.record.id).sort())) throw new DomainError("INVALID_RECONCILIATION", "Every concept requires one identity decision.");
          for (const d of decision.decisions) {
            const e = requireValue(values.find(e => e.record.id === d.conceptID));
            if (d.reviewReason && d.mergeWithID) throw new DomainError("MERGE_REVIEW_REQUIRED", "An identity match requires review. Reopen the draft before saving.", 409);
            e.mergeTargetID = d.mergeWithID; e.acceptMerge = !!d.mergeWithID;
          }
          const needsFactReview = retainFactReviews(prepared, decision.factReviews, current);
          prepared.updates.push(...asJSON(decision.updates) as JSONValue[]);
          if (needsFactReview) {
            await this.queue.complete(job, async tx => {
              const latest = requireValue((await tx.select().from(imports).where(and(eq(imports.userId, job.userId), eq(imports.id, row.id))).for("update"))[0]); expected(latest.version, row.version);
              await tx.update(imports).set({ draft: draftJSON(prepared), version: latest.version + 1, updatedAt: new Date() }).where(eq(imports.id, row.id));
              await tx.update(jobs).set({ progress: { stage: "review", message: "New source warnings need review before saving." } }).where(eq(jobs.id, job.id));
              await invalidate(tx, job.userId, "imports", row.subjectId, latest.version + 1);
            });
            return;
          }
          checkpoint.commitHeadID = head.revisionId; checkpoint.commitImportVersion = row.version; checkpoint.commitPrepared = draftJSON(prepared); checkpoint.commitOffset = offset + 25;
          await this.queue.checkpoint(job, checkpoint, { stage: "preparingCommit", completed: Math.min(offset + 25, batch.length), total: batch.length });
        }
      }
    }
    const semantic = head.revisionId !== row.baseRevisionId ? await semanticUpdates(this.ai, this.queue, job, head.name, base, await snapshot(this.db, job.userId, row.subjectId), prepared.entries.filter(e => e.selected && !e.reviewReason && !(e.record.kind === "concept" && (e.acceptMerge || e.mergeDecisionLocked))).map(e => e.record), checkpoint, signal) : { merges: [], updates: [] };
    prepared.updates.push(...semantic.updates);
    await this.queue.complete(job, async tx => {
      const subject = await ownedSubject(tx, job.userId, row.subjectId, true), currentImport = requireValue((await tx.select().from(imports).where(eq(imports.id, row.id)).for("update"))[0]);
      if (subject.revisionId !== head.revisionId) throw new DomainError("HEAD_CHANGED", "This subject changed during reconciliation. Retry to use the latest revision.", 409);
      if (currentImport.status === "saved") return;
      expected(currentImport.version, Number(job.input.inputVersion));
      if (Object.keys(jsonObject(job.input.choices ?? {})).length) expected(subject.version, Number(job.input.subjectVersion));
      const draft = prepared, before = await snapshot(tx, job.userId, row.subjectId), map = new Map(before.map(r => [r.id, structuredClone(r)]));
      const selectedConcepts = new Set(draft.entries.filter(e => e.selected && e.record.kind === "concept").map(e => e.record.id));
      const selected = draft.entries.filter(e => e.selected && (e.record.kind !== "placement" || selectedConcepts.has(stringValue(e.record.fields.conceptID)) || before.some(r => r.kind === "concept" && !r.isRetired && r.id === e.record.fields.conceptID))), remap = new Map<string, string>();
      for (const e of selected) if (e.acceptMerge && e.mergeTargetID) remap.set(e.record.id, e.mergeTargetID);
      const resolveID = (id: string) => { const visited = new Set<string>(); while (remap.has(id)) { if (visited.has(id)) throw new DomainError("INVALID_MERGE", "Identity decisions contain a cycle."); visited.add(id); id = remap.get(id)!; } return id; };
      const supplied = [...before, ...selected.map(e => e.record)];
      for (const merge of semantic.merges.sort((a, b) => (supplied.find(r => r.id === a.incomingID)?.kind === "concept" ? 0 : 1) - (supplied.find(r => r.id === b.incomingID)?.kind === "concept" ? 0 : 1))) {
        const a = supplied.find(r => r.id === merge.incomingID), b = supplied.find(r => r.id === merge.existingID); if (!a || !b || a.kind !== b.kind) continue;
        if (a.kind === "fact" && (resolveID(stringValue(a.fields.conceptID)) !== resolveID(stringValue(b.fields.conceptID)) || a.fields.kind !== b.fields.kind || normalizeName(stringValue(a.fields.qualifications)) !== normalizeName(stringValue(b.fields.qualifications)))) continue;
        if (a.kind === "connection" && (a.fields.kind !== b.fields.kind || ["fromConceptID", "toConceptID"].some(field => resolveID(stringValue(a.fields[field])) !== resolveID(stringValue(b.fields[field]))))) continue;
        remap.set(a.id, b.id);
      }
      // Normalize exact duplicates without another provider request, preserving saved identities.
      for (const kind of ["topic", "topic", "topic", "fact", "connection"]) {
        const seen = new Map<string, LibraryEntity>();
        for (const record of [...before.filter(r => !r.isRetired), ...selected.map(e => e.record)].filter(r => r.kind === kind && !r.fields.keepSeparate)) {
          const parent = (field: string) => typeof record.fields[field] === "string" ? resolveID(record.fields[field] as string) : "root";
          const signature = kind === "topic" ? parent("parentID") + "/" + normalizeName(stringValue(record.fields.name)) : kind === "fact" ? [parent("conceptID"), record.fields.kind, normalizeName(stringValue(record.fields.statement)), normalizeName(stringValue(record.fields.qualifications))].join("/") : [parent("fromConceptID"), parent("toConceptID"), record.fields.kind, normalizeName(stringValue(record.fields.explanation))].join("/");
          const previous = seen.get(signature), incoming = selected.find(e => e.record.id === record.id);
          if (previous && incoming && !incoming.reviewReason && record.id !== previous.id && record.protectedFields.every(field => canonical(record.fields[field] ?? null) === canonical(previous.fields[field] ?? null))) remap.set(record.id, resolveID(previous.id));
          else if (!previous) seen.set(signature, record);
        }
      }
      const incoming = selected.map(e => {
        const record = structuredClone(e.record);
        if (record.kind === "concept") {
          const suggestion = jsonObject(record.fields.resolutionSuggestion ?? {});
          record.fields.wordings = jsonArray(record.fields.wordings).map(raw => {
            const wording = jsonObject(raw); if (wording.sourceID !== row.sourceId) return raw;
            const current = { name: record.fields.name ?? "", aliases: record.fields.aliases ?? [], explanation: record.fields.explanation ?? "" };
            return { ...wording, edited: canonical(wording.original) === canonical(current) ? null : current,
              ...(suggestion.status ? { resolutionSuggestion: { ...suggestion, changedLibraryName: !remap.has(record.id) && suggestion.status === "applied" && record.fields.name === suggestion.suggestedName } } : {}) };
          });
        }
        if (["concept", "fact", "connection"].includes(record.kind)) record.fields.reviewNote = e.reviewReason ?? record.fields.reviewNote ?? null;
        for (const field of ["conceptID", "fromConceptID", "toConceptID"]) if (typeof record.fields[field] === "string") record.fields[field] = resolveID(record.fields[field] as string);
        return record;
      });
      // Prepare every incoming target before materializing merges. A canonical target
      // later in source order must retain its edited wordings and review provenance too.
      const incomingByID = new Map(incoming.map(record => [record.id, record]));
      for (const record of incoming) {
        if (["concept", "fact", "connection", "topic"].includes(record.kind) && remap.has(record.id)) {
          const targetID = resolveID(record.id), target = map.get(targetID) ?? incomingByID.get(targetID);
          if (!target || target.kind !== record.kind) throw new DomainError("INVALID_MERGE", "Select a matching identity target in this subject first.");
          const merged = structuredClone(target);
          merged.protectedFields = [...new Set([...merged.protectedFields, ...record.protectedFields])];
          merged.fields.sourceIDs = [...new Set([...jsonArray(merged.fields.sourceIDs), row.sourceId])];
          merged.fields.wordings = [...jsonArray(merged.fields.wordings), ...jsonArray(record.fields.wordings)];
          merged.fields.evidence = [...new Map([...jsonArray(merged.fields.evidence), ...jsonArray(record.fields.evidence)].map(e => [canonical(e), e])).values()];
          if (record.kind === "connection") merged.fields.supportingFactIDs = [...new Set([...jsonArray(merged.fields.supportingFactIDs), ...jsonArray(record.fields.supportingFactIDs)])];
          map.set(targetID, merged); map.set(record.id, { ...record, isRetired: true, redirectID: targetID });
        } else if (record.kind === "placement") {
          if (record.fields.topicID && ![...map.values(), ...selected.map(e => e.record)].some(r => r.kind === "topic" && !r.isRetired && r.id === record.fields.topicID)) record.fields.topicID = null;
          const existing = [...map.values()].find(r => r.kind === "placement" && !r.isRetired && r.fields.conceptID === record.fields.conceptID);
          if (!existing) map.set(record.id, record);
        } else if (record.kind !== "connection" || record.fields.fromConceptID !== record.fields.toConceptID) {
          if (!map.has(record.id)) map.set(record.id, record);
        }
      }
      for (const record of map.values()) if (!record.isRetired) {
        for (const field of ["conceptID", "fromConceptID", "toConceptID", "parentID", "topicID", "entityID"]) if (typeof record.fields[field] === "string") record.fields[field] = resolveID(record.fields[field] as string);
        if (Array.isArray(record.fields.supportingFactIDs)) record.fields.supportingFactIDs = [...new Set(record.fields.supportingFactIDs.map(id => typeof id === "string" ? resolveID(id) : id))];
      }
      // Do not retain newly suggested topic branches used only by deselected concepts.
      const newTopicIDs = new Set(selected.filter(e => e.record.kind === "topic").map(e => e.record.id)), usedTopics = new Set<string>();
      for (const p of map.values()) if (p.kind === "placement" && typeof p.fields.topicID === "string") {
        let id: string | null = p.fields.topicID; while (id && !usedTopics.has(id)) { usedTopics.add(id); const parent: JSONValue | undefined = map.get(id)?.fields.parentID; id = typeof parent === "string" ? parent : null; }
      }
      for (const id of newTopicIDs) if (!usedTopics.has(id)) map.delete(id);
      const selectedIDs = new Set(selected.map(e => resolveID(e.record.id)));
      for (const record of map.values()) if (record.kind === "placement" && selectedIDs.has(stringValue(record.fields.conceptID))) selectedIDs.add(record.id);
      const choices = jsonObject(job.input.choices ?? {}), conflicts: JSONObject[] = [], updatedFields = new Set<string>();
      for (const raw of draft.updates) {
        const update = jsonObject(raw), id = resolveID(stringValue(update.entityID)), field = stringValue(update.field), target = map.get(id);
        const allowed: Record<string, string[]> = { concept: ["name", "explanation"], fact: ["statement", "qualifications", "kind"], connection: ["explanation", "kind"], topic: ["name", "parentID"], placement: ["topicID"] };
        if (!target || !selectedIDs.has(id) || !allowed[target.kind]?.includes(field) || jsonArray(update.supportingFactIDs).some(raw => typeof raw !== "string" || map.get(resolveID(raw))?.kind !== "fact")) continue;
        const key = id + "/" + field, value = ["parentID", "topicID"].includes(field) && update.value === "" ? null : update.value ?? null;
        if (["parentID", "topicID"].includes(field) ? value !== null && (typeof value !== "string" || !map.has(value)) : typeof value !== "string") continue;
        if (field === "kind" && !(target.kind === "fact" ? factKinds : connectionKinds).some(kind => kind === value)) continue;
        if (["name", "statement", "explanation"].includes(field) && typeof value === "string" && !value.trim()) continue;
        if (canonical(target.fields[field] ?? null) === canonical(value)) continue;
        if (updatedFields.has(key)) continue; updatedFields.add(key);
        const baseline = baseByID.get(id)?.fields[field] ?? null;
        if (target.protectedFields.includes(field) || target.fields.isLocked === true || canonical(baseline) !== canonical(target.fields[field] ?? null)) {
          if (choices[key] !== "incoming" && choices[key] !== "current") { conflicts.push({ id: key, entityID: id, field, current: target.fields[field] ?? null, incoming: value, reason: update.reason ?? "" }); continue; }
          if (choices[key] === "current") continue;
        }
        const previous = target.fields[field]; target.fields[field] = value;
        try { await validateGraph(tx, job.userId, row.subjectId, [...map.values()]); }
        catch (error) { if (!(error instanceof DomainError)) throw error; if (previous === undefined) delete target.fields[field]; else target.fields[field] = previous; }
      }
      if (conflicts.length) {
        await tx.delete(pendingDecisions).where(and(eq(pendingDecisions.userId, job.userId), eq(pendingDecisions.importId, row.id)));
        await tx.insert(pendingDecisions).values({ userId: job.userId, subjectId: row.subjectId, importId: row.id, state: { jobID: job.id, importVersion: currentImport.version, subjectVersion: subject.version, conflicts } });
        await invalidate(tx, job.userId, "decisions", row.subjectId, subject.version); return;
      }
      for (const e of selected.filter(e => ["concept", "fact", "connection"].includes(e.record.kind))) {
        if (!map.has(resolveID(e.record.id))) continue;
        const id = randomUUID(); map.set(id, { id, subjectID: row.subjectId, kind: "contribution", isRetired: false, redirectID: null, protectedFields: [],
          fields: { entityID: resolveID(e.record.id), entityKind: e.record.kind, sourceID: row.sourceId, original: e.original, evidence: e.record.fields.evidence ?? [], reviewNote: e.reviewReason, importID: row.id } });
      }
      await validateGraph(tx, job.userId, row.subjectId, [...map.values()]);
      const result = await writeRevision(tx, job.userId, subject, stringValue(job.input.operationID), before, [...map.values()], "import", "Imported source");
      await tx.update(imports).set({ status: "saved", version: currentImport.version + 1, updatedAt: new Date() }).where(eq(imports.id, row.id));
      await tx.delete(pendingDecisions).where(and(eq(pendingDecisions.userId, job.userId), eq(pendingDecisions.importId, row.id)));
      const prefs = (await tx.select().from(preferences).where(eq(preferences.userId, job.userId)))[0];
      const preparation = prefs?.values.preparationSelection ? selectionSchema.parse(prefs.values.preparationSelection) : { ...(prefs?.values.aiSelection ? selectionSchema.parse(prefs.values.aiSelection) : { funding: "chatgpt" as const, connectionID: null, model: "gpt-6-luna" }), reasoning: "medium" };
      await tx.insert(jobs).values({ userId: job.userId, subjectId: row.subjectId, kind: "prepareRecall", input: { revisionID: result.revisionID }, selection: preparation, aiConnectionId: preparation.connectionID });
      await invalidate(tx, job.userId, "imports", row.subjectId, currentImport.version + 1);
    });
  }

  private async reviewSource(job: ClaimedJob, row: typeof imports.$inferSelect, draft: DraftState, source: SourcePassage[], signal: AbortSignal, checkpoint: JSONObject): Promise<DraftState> {
    if (checkpoint.reviewProgress) draft = state(jsonObject(checkpoint.reviewProgress));
    const completed = new Set(jsonArray(checkpoint.reviewCompleted).filter((s): s is string => typeof s === "string"));
    const saved = await snapshot(this.db, job.userId, row.subjectId);
    const inferred = draft.entries.filter(e => e.record.kind === "connection" && e.record.fields.isInferred === true);
    const issues: SourceReviewIssue[] = draft.entries.filter(e => e.reviewReason && !inferred.includes(e)).map(e => ({ id: randomUUID(), entryID: e.record.id, passageID: null, reason: e.reviewReason! }));
    for (const raw of draft.coverage) {
      const c = jsonObject(raw), citedByFact = draft.entries.some(e => e.record.kind === "fact" && jsonArray(e.record.fields.evidence).some(raw => jsonObject(raw).segmentID === c.segmentID));
      if (c.disposition === "uncertain" || (c.contentKind === "substantive" && !citedByFact)) issues.push({ id: randomUUID(), entryID: null, passageID: stringValue(c.segmentID), reason: stringValue(c.reason) || "Check that every teachable claim is represented as an individual fact." });
    }
    for (const e of inferred) issues.push({ id: randomUUID(), entryID: e.record.id, passageID: null, inferred: true, reason: "Independently verify the complete inferred relationship against original source evidence." });
    // Include original passages from saved supporting facts, scoped to this owner
    // and subject. A saved paraphrase alone cannot certify an inference.
    const supportIDs = new Set(inferred.flatMap(e => jsonArray(e.record.fields.supportingFactIDs)));
    const extraSources = [...new Set(saved.filter(r => supportIDs.has(r.id)).flatMap(r => jsonArray(r.fields.evidence).map(raw => stringValue(jsonObject(raw).sourceID))))].filter(id => id && id !== row.sourceId);
    const originals: ReviewPassage[] = source.map(p => ({ ...p, sourceID: row.sourceId }));
    if (extraSources.length) originals.push(...(await this.db.select().from(passages).where(and(eq(passages.userId, job.userId), eq(passages.subjectId, row.subjectId), inArray(passages.sourceId, extraSources))).orderBy(asc(passages.sourceId), asc(passages.ordinal))).map(p => ({ id: p.id, sourceID: p.sourceId, text: p.text, page: p.page, section: p.section })));
    const firstPassage = (issue: SourceReviewIssue) => {
      if (issue.passageID) return source.findIndex(p => p.id === issue.passageID);
      const refs = affectedEntries(issue, draft.entries, row.sourceId).flatMap(e => jsonArray(e.record.fields.evidence).map(raw => jsonObject(raw)));
      const index = source.findIndex(p => refs.some(r => r.sourceID === row.sourceId && r.segmentID === p.id));
      return index < 0 ? source.length : index;
    };
    issues.sort((a, b) => firstPassage(a) - firstPassage(b) || Number(!!a.inferred) - Number(!!b.inferred));
    const passageMap = new Map(source.map(p => [p.id, p.text]));
    const references = (values: { sourceID: string; segmentID: string; quote: string }[]) => values.map(e => {
      const original = passageMap.get(e.segmentID), normalize = (s: string) => s.normalize("NFKC").replace(/\u00ad/g, "").replace(/\s+/g, " ").trim();
      if (e.sourceID !== row.sourceId || !original || !normalize(e.quote) || !normalize(original).includes(normalize(e.quote))) throw new DomainError("INVALID_REVIEW", "Source review returned an invalid quotation.");
      return { ...e, sourceID: row.sourceId };
    });
    const cached = new Map<string, { verdict: SourceReviewVerdict; input: string }>();
    const issueInput = (issue: SourceReviewIssue) => issue.inferred ? inferenceInput(requireValue(draft.entries.find(e => e.record.id === issue.entryID)), draft.entries, saved) : canonical(affectedEntries(issue, draft.entries, row.sourceId));
    const canSelect = (entry: DraftEntry) => {
      const records = new Map([...saved, ...draft.entries.map(e => e.record)].map(r => [r.id, r]));
      const resolve = (value: JSONValue | undefined): string | null => {
        if (typeof value !== "string") return null;
        const seen = new Set<string>(); let id = value;
        while (!seen.has(id)) {
          seen.add(id); const e = draft.entries.find(e => e.record.id === id), record = records.get(id);
          const next = e?.acceptMerge ? e.mergeTargetID : record?.redirectID;
          if (!next) return record?.kind === "concept" && !record.isRetired ? id : null;
          id = next;
        }
        return null;
      };
      const has = (id: JSONValue | undefined, kind: LibraryEntity["kind"]) => {
        if (typeof id !== "string") return false;
        const e = draft.entries.find(e => e.record.id === id), record = records.get(id);
        return record?.kind === kind && !record.isRetired && (!e || (e.selected && !e.reviewReason)) && !(draft.existingFactReviews ?? []).some(raw => { const warning = jsonObject(raw); return warning.factID === id && warning.reviewed !== true; });
      };
      const f = entry.record.fields, from = resolve(f.fromConceptID), to = resolve(f.toConceptID);
      if (!from || !to || from === to || !has(from, "concept") || !has(to, "concept") || !has(f.fromConceptID, "concept") || !has(f.toConceptID, "concept") || !jsonArray(f.supportingFactIDs).length || jsonArray(f.supportingFactIDs).some(id => !has(id, "fact"))) return false;
      return ![...saved.filter(r => !r.isRetired), ...draft.entries.filter(e => e.selected).map(e => e.record)].some(r => r.id !== entry.record.id && r.kind === "connection" && resolve(r.fields.fromConceptID) === from && resolve(r.fields.toConceptID) === to && r.fields.kind === f.kind && normalizeName(stringValue(r.fields.explanation)) === normalizeName(stringValue(f.explanation)));
    };
    for (const issue of issues) {
      const issueKey = issue.inferred ? "inferred:" + issue.entryID : issue.entryID ?? issue.passageID ?? issue.id;
      if (completed.has(issueKey)) continue;
      const saveProgress = async () => { completed.add(issueKey); checkpoint.reviewCompleted = [...completed]; checkpoint.reviewProgress = draftJSON(draft); await this.queue.checkpoint(job, checkpoint, { stage: "reviewing", completed: completed.size, total: issues.length }); };
      signal.throwIfAborted(); const before = structuredClone(draft), affected = affectedEntries(issue, draft.entries, row.sourceId);
      const citedIDs = new Set(affected.flatMap(e => jsonArray(e.record.fields.evidence).map(raw => stringValue(jsonObject(raw).segmentID)))); if (issue.passageID) citedIDs.add(issue.passageID);
      try {
        if (cached.get(issue.id)?.input !== issueInput(issue)) {
          let batch = issues.slice(issues.indexOf(issue)).filter(i => !completed.has(i.inferred ? "inferred:" + i.entryID : i.entryID ?? i.passageID ?? i.id)).slice(0, 4);
          const inputs = new Map(batch.map(i => [i.id, issueInput(i)]));
          let results: Map<string, SourceReviewVerdict>;
          try { results = await sourceReviewBatch(this.ai, job, row.sourceId, batch, draft.entries, saved, originals, signal); }
          catch (error) {
            if (!(error instanceof DomainError) || error.code !== "INVALID_REVIEW_CONTEXT" || batch.length === 1) throw error;
            batch = [issue]; results = await sourceReviewBatch(this.ai, job, row.sourceId, batch, draft.entries, saved, originals, signal);
          }
          for (const i of batch) cached.set(i.id, { input: inputs.get(i.id)!, verdict: results.get(i.id) ?? { disposition: "needsReview", reason: "Source review still needs broader context. Review the entry against the original source.", evidence: [], repairs: {}, missingFacts: [], passageAssessment: null, needsMoreContext: true } });
        }
        const verdict = requireValue(cached.get(issue.id)).verdict;
        if (issue.inferred) {
          const target = requireValue(affected[0]);
          target.selected = false;
          target.record.fields.inferenceReview = { status: verdict.disposition === "supported" && !verdict.needsMoreContext ? "supported" : "needsReview", reason: verdict.reason, evidence: asJSON(verdict.evidence), inputSignature: issueInput(issue) };
          if (verdict.disposition === "supported" && !verdict.needsMoreContext) {
            target.reviewReason = null;
            // Explicit rechecks preserve the user's excluded selections.
            target.selected = (job.input.recheck !== true || before.entries.find(e => e.record.id === target.record.id)?.selected === true) && canSelect(target);
          } else target.reviewReason = verdict.reason;
          await saveProgress(); continue;
        }
        if (verdict.needsMoreContext) { draft.reviewNotes.push(verdict.reason); await saveProgress(); continue; }
        if (verdict.disposition === "needsReview") { await saveProgress(); continue; }
        if (!verdict.evidence.length) throw new DomainError("INVALID_REVIEW", "Source review requires original evidence.");
        references(verdict.evidence);
        const hasRepairs = Object.values(verdict.repairs).some(fields => Object.values(fields as Record<string, unknown>).some(v => v !== null));
        if (verdict.disposition === "supported" && (hasRepairs || verdict.missingFacts.length)) throw new DomainError("INVALID_REVIEW", "A supported verdict cannot silently repair wording or add facts.");
        const anchors = issue.passageID ? new Set([issue.passageID]) : citedIDs;
        if (issue.passageID && (!verdict.passageAssessment || !verdict.evidence.some(e => e.segmentID === issue.passageID))) throw new DomainError("INVALID_REVIEW", "Assess and cite the actual reviewed passage explicitly.");
        for (const f of verdict.missingFacts) if (!f.evidence.some(e => anchors.has(e.segmentID))) throw new DomainError("INVALID_REVIEW", "A recovered fact must cite the passage or material under review.");
        for (const [id, fields] of Object.entries(verdict.repairs)) {
          const target = requireValue(draft.entries.find(e => e.record.id === id));
          for (const [field, raw] of Object.entries(fields as Record<string, unknown>)) if (raw !== null) {
            const values = z.array(z.string()).parse(raw);
            if (verdict.disposition !== "repair" || (field !== "aliases" && values.length !== 1) || target.record.protectedFields.includes(field)) throw new DomainError("INVALID_REVIEW", "Source review attempted an unsupported repair.");
            if (field === "kind" && !(target.record.kind === "fact" ? factKinds : connectionKinds).some(k => k === values[0])) throw new DomainError("INVALID_REVIEW", "Source review returned an invalid relationship or fact kind.");
            if (["fromConceptID", "toConceptID"].includes(field) && !draft.entries.some(e => e.record.id === values[0] && e.record.kind === "concept")) throw new DomainError("INVALID_REVIEW", "A source repair referenced an unknown concept.");
            target.record.fields[field] = field === "aliases" ? values : values[0]!;
            target.record.fields.evidence = [...jsonArray(target.record.fields.evidence), ...references(verdict.evidence)];
          }
        }
        for (const f of verdict.missingFacts) {
          if (verdict.disposition !== "repair" || !draft.entries.some(e => e.record.id === f.conceptID && e.record.kind === "concept") || !f.evidence.length) throw new DomainError("INVALID_REVIEW", "A recovered fact requires a source-grounded concept and evidence.");
          if (!draft.entries.some(e => e.record.kind === "fact" && e.record.fields.statement === f.statement && e.record.fields.conceptID === f.conceptID && e.record.fields.kind === f.kind && e.record.fields.qualifications === f.qualifications)) draft.entries.push(entry(row.subjectId, "fact", randomUUID(), { conceptID: f.conceptID, sourceID: row.sourceId, statement: f.statement, kind: f.kind, qualifications: f.qualifications, evidence: references(f.evidence), original: { statement: f.statement, kind: f.kind, qualifications: f.qualifications } }));
        }
        if (issue.passageID && verdict.passageAssessment === "substantive" && !draft.entries.some(e => e.record.kind === "fact" && jsonArray(e.record.fields.evidence).some(ref => jsonObject(ref).segmentID === issue.passageID))) throw new DomainError("INVALID_REVIEW", "A substantive passage needs an individual recovered or existing draft fact citing it before coverage can be cleared.");
        for (const e of affected) e.reviewReason = null;
        if (issue.passageID) {
          const coverage = draft.coverage.map(jsonObject).find(c => c.segmentID === issue.passageID);
          if (coverage) { coverage.disposition = verdict.passageAssessment === "structural" ? "excluded" : "extracted"; coverage.reason = verdict.reason; coverage.contextRequest = null; }
        }
      } catch (error) {
        if (!(error instanceof DomainError) || !["INVALID_AI_RESPONSE", "INVALID_REVIEW", "INVALID_REVIEW_CONTEXT"].includes(error.code)) throw error;
        draft = before; draft.reviewNotes.push(error.message);
        if (issue.inferred) {
          const target = requireValue(draft.entries.find(e => e.record.id === issue.entryID));
          target.selected = false; target.reviewReason = "This inferred connection could not be verified. Review its original evidence before including it.";
          target.record.fields.inferenceReview = { status: "needsReview", reason: target.reviewReason, evidence: [], inputSignature: issueInput(issue) };
        }
      }
      await saveProgress();
    }
    for (const target of draft.entries.filter(e => e.record.kind === "connection" && e.record.fields.isInferred === true)) {
      const review = jsonObject(target.record.fields.inferenceReview ?? {});
      if (review.status === "supported" && review.inputSignature !== inferenceInput(target, draft.entries, saved)) {
        target.selected = false; target.reviewReason = "Supporting material changed during source review. Review this inferred connection before including it.";
        target.record.fields.inferenceReview = { ...review, status: "needsReview", reason: target.reviewReason };
      } else if (target.selected && !canSelect(target)) target.selected = false;
    }
    excludeUnavailableDependents(draft, saved);
    return draft;
  }
  private async suggestNames(job: ClaimedJob, row: typeof imports.$inferSelect, draft: DraftState, passages: SourcePassage[], signal: AbortSignal, checkpoint: JSONObject): Promise<DraftState> {
    if (checkpoint.namingProgress) draft = state(jsonObject(checkpoint.namingProgress));
    const candidates = draft.entries.filter(e => e.record.kind === "concept" && (e.reviewReason || draft.entries.some(f => f.record.kind === "fact" && f.record.fields.conceptID === e.record.id && f.reviewReason)));
    const schema = z.strictObject({ decisions: z.array(z.strictObject({ conceptID: z.string(), disposition: z.enum(["suggest", "unchanged"]), suggestedName: z.string().nullable(), classification: z.string().nullable(), basis: z.enum(["sourceContext", "generalKnowledge"]), rationale: z.string(), evidence: z.array(z.strictObject({ segmentID: z.string(), quote: z.string() })) })) });
    for (let offset = Number(checkpoint.namingOffset ?? 0); offset < candidates.length; offset += 4) {
      const batch = candidates.slice(offset, offset + 4), refs = new Set(batch.flatMap(e => jsonArray(e.record.fields.evidence).map(raw => stringValue(jsonObject(raw).segmentID))));
      const result = await structured(this.ai, job.userId, requireValue(job.selection), "naming_suggestions", policies.naming_instructions, { subject: (await ownedSubject(this.db, job.userId, row.subjectId)).name,
        concepts: asJSON(batch.map(e => ({ ...e.record.fields, id: e.record.id, reviewReason: e.reviewReason, facts: draft.entries.filter(f => f.record.fields.conceptID === e.record.id).map(f => f.record.fields), passages: passages.filter(p => refs.has(p.id)) }))) }, schema, signal);
      for (const d of result.decisions) {
        const target = batch.find(e => e.record.id === d.conceptID);
        if (!target || d.disposition !== "suggest" || (!d.suggestedName && !d.classification) || d.rationale.length > 2000 || d.evidence.some(e => !passages.some(p => p.id === e.segmentID && p.text.includes(e.quote)))) continue;
        target.record.fields.resolutionSuggestion = { ...d, model: requireValue(job.selection).model, status: "pending", previousName: null, evidence: d.evidence.map(e => ({ ...e, sourceID: row.sourceId })) };
      }
      checkpoint.namingProgress = draftJSON(draft); checkpoint.namingOffset = offset + 4;
      await this.queue.checkpoint(job, checkpoint, { stage: "naming", completed: Math.min(offset + 4, candidates.length), total: candidates.length });
    }
    return draft;
  }
}
