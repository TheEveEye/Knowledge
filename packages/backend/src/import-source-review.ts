import { z } from "zod";
import type { JSONObject, LibraryEntity, SourcePassage } from "@knowledge/contracts";
import { AIService } from "./ai.js";
import { asJSON, factKinds, structured } from "./structured.js";
import { hash, DomainError, jsonArray, jsonObject, requireValue } from "./core.js";
import type { ClaimedJob } from "./jobs.js";
import type { DraftEntry } from "./imports.js";
import { policies } from "./policies.js";

export interface SourceReviewIssue {
  id: string;
  entryID: string | null;
  passageID: string | null;
  reason: string;
  inferred?: boolean;
}
export type ReviewPassage = SourcePassage & { sourceID: string };
const evidence = z.array(z.strictObject({ sourceID: z.string().min(1), segmentID: z.string().min(1), quote: z.string().min(1) }));
const missingFact = z.strictObject({ conceptID: z.string(), statement: z.string().min(1), kind: z.enum(factKinds), qualifications: z.string(), evidence });
const verdictSchema = z.strictObject({
  disposition: z.enum(["supported", "repair", "needsReview"]), reason: z.string().min(1), evidence,
  repairs: z.record(z.string(), z.record(z.string(), z.array(z.string()).nullable())),
  missingFacts: z.array(missingFact), passageAssessment: z.enum(["substantive", "structural"]).nullable(), needsMoreContext: z.boolean(),
});
export type SourceReviewVerdict = z.infer<typeof verdictSchema>;
export function affectedEntries(issue: SourceReviewIssue, entries: DraftEntry[], sourceID: string) {
  return issue.entryID ? entries.filter(e => e.record.id === issue.entryID)
    : entries.filter(e => jsonArray(e.record.fields.evidence).some(raw => { const ref = jsonObject(raw); return ref.sourceID === sourceID && ref.segmentID === issue.passageID; }));
}

// Includes endpoint identity, supporting content and selections, but excludes the
// verifier's own metadata. A verdict cannot survive a repair to its premises.
export function inferenceInput(entry: DraftEntry, entries: DraftEntry[], saved: LibraryEntity[]) {
  const { inferenceReview: _, ...fields } = entry.record.fields;
  const ids = new Set([fields.fromConceptID, fields.toConceptID, ...jsonArray(fields.supportingFactIDs)]);
  const context = [];
  for (const id of ids) {
    const incoming = entries.find(e => e.record.id === id);
    const record = incoming?.record ?? saved.find(r => r.id === id);
    const next = incoming?.acceptMerge ? incoming.mergeTargetID : record?.redirectID;
    if (next) ids.add(next);
    if (typeof record?.fields.conceptID === "string") ids.add(record.fields.conceptID);
    context.push({ record: record ? reviewRecord(record) : null, retired: record?.isRetired ?? null, redirectID: record?.redirectID ?? null,
      selected: incoming?.selected ?? true, reviewReason: incoming?.reviewReason ?? null, mergeTargetID: next ?? null });
  }
  return hash({ fields, context });
}

const inferredInstructions = `
Issues marked inferred are independent verification of proposed connections, not requests to generate relationships.
For those issues, supported means the ORIGINAL supplied passages jointly establish the full relationship:
both endpoint identities, kind, direction, explanation, scope, negation, attribution and qualifications.
Reasoning across multiple explicit source claims is allowed; outside knowledge, plausible association alone,
or a causal/transitive leap is not. Derived facts and prior suggestions are proposals, not proof.
Verify supporting facts against their original passages as part of checking the relationship.
Do not strengthen association into causation, reverse direction, or remove uncertainty.
Use needsReview for unsupported, ambiguous or duplicate proposals and explain the specific reason.
Compare existing connections for redundant relationships. For equivalent proposals in this batch, retain one
supported canonical proposal (the lowest UUID) and mark the others needsReview as duplicates; never reject
every member solely because they duplicate one another. Do not repair or generate content for inferred issues:
repairs must be {}, missingFacts [], passageAssessment null. Supported requires exact original evidence.
Evidence always includes the supplied sourceID and original passage id as segmentID.
For ordinary source issues, evidence must belong to the importSourceID, even when other documents are context.
Only supplied passages can establish support. Request more context if needed; never certify unseen documents.
Evaluate each issue separately; supporting one item does not approve the rest of the batch.`;

function reviewRecord(record: LibraryEntity) {
  // Wording history and previous AI judgments are neither verification evidence
  // nor necessary context. Keep bounded requests focused on the current claims.
  const fields = Object.fromEntries(["name", "aliases", "explanation", "statement", "qualifications", "kind", "conceptID", "fromConceptID", "toConceptID", "supportingFactIDs", "evidence"]
    .filter(field => record.fields[field] !== undefined).map(field => [field, record.fields[field]]));
  return { id: record.id, kind: record.kind, fields };
}

export async function sourceReviewBatch(ai: AIService, job: ClaimedJob, sourceID: string, issues: SourceReviewIssue[], entries: DraftEntry[], saved: LibraryEntity[], passages: ReviewPassage[], signal: AbortSignal) {
  const decisions: Record<string, z.ZodType> = {};
  const affected = [...new Map(issues.flatMap(issue => affectedEntries(issue, entries, sourceID)).map(e => [e.record.id, e])).values()];
  for (const issue of issues) {
    const editable: Record<string, z.ZodType> = {};
    if (!issue.inferred) for (const e of affectedEntries(issue, entries, sourceID)) {
      const names = e.record.protectedFields.length ? [] : e.record.kind === "concept" ? ["name", "aliases", "explanation"] : e.record.kind === "fact" ? ["statement", "qualifications", "kind"] : e.record.kind === "connection" ? ["explanation", "kind", "fromConceptID", "toConceptID"] : [];
      editable[e.record.id] = z.strictObject(Object.fromEntries(names.map(name => [name, z.array(z.string()).nullable()])));
    }
    decisions[issue.id] = verdictSchema.extend({
      disposition: issue.inferred ? z.enum(["supported", "needsReview"]) : z.enum(["supported", "repair", "needsReview"]),
      repairs: z.strictObject(editable), missingFacts: issue.inferred ? z.array(missingFact).max(0) : z.array(missingFact),
      passageAssessment: issue.passageID ? z.enum(["substantive", "structural"]).nullable() : z.null(),
    });
  }
  const records = new Map([...saved, ...entries.map(e => e.record)].map(r => [r.id, r]));
  const supportingIDs = new Set(affected.flatMap(e => jsonArray(e.record.fields.supportingFactIDs)));
  const facts = [...records.values()].filter(r => r.kind === "fact" && (supportingIDs.has(r.id) || affected.some(e => e.record.id === r.id)));
  const endpointIDs = new Set([...affected, ...facts.map(record => ({ record }))].flatMap(e => [e.record.fields.conceptID, e.record.fields.fromConceptID, e.record.fields.toConceptID]));
  for (const id of endpointIDs) {
    const incoming = entries.find(e => e.record.id === id), record = records.get(String(id));
    const canonicalID = incoming?.acceptMerge ? incoming.mergeTargetID : record?.redirectID;
    if (canonicalID) endpointIDs.add(canonicalID);
  }
  const concepts = [...records.values()].filter(r => r.kind === "concept" && (issues.some(i => i.passageID) && entries.some(e => e.record.id === r.id) || endpointIDs.has(r.id) || affected.some(e => e.record.id === r.id)));
  const anchors = new Set([...affected.map(e => e.record), ...facts].flatMap(r => jsonArray(r.fields.evidence).map(raw => { const ref = jsonObject(raw); return ref.sourceID + "/" + ref.segmentID; })));
  for (const issue of issues) if (issue.passageID) anchors.add(sourceID + "/" + issue.passageID);
  const results = new Map<string, SourceReviewVerdict>();
  const originals = new Map(passages.map(p => [p.sourceID + "/" + p.id, p.text]));
  for (const radius of [3, 6, 18]) {
    const pending = issues.filter(i => !results.has(i.id));
    if (!pending.length) break;
    const positions = passages.flatMap((p, i) => anchors.has(p.sourceID + "/" + p.id) ? [i] : []);
    const wanted = new Set<number>();
    for (const position of positions) for (let i = Math.max(0, position - radius); i <= Math.min(passages.length - 1, position + radius); i++) {
      if (passages[i]!.sourceID === passages[position]!.sourceID) wanted.add(i);
    }
    if (!positions.length) for (let i = 0; i < Math.min(passages.length, radius * 2 + 1); i++) if (passages[i]!.sourceID === sourceID) wanted.add(i);
    const window = [...wanted].sort((a, b) => a - b).map(i => passages[i]!);
    const input = { importSourceID: sourceID, issues: asJSON(pending.map(issue => ({ ...issue, dependents: affectedEntries(issue, entries, sourceID).map(e => ({ id: e.record.id, kind: e.record.kind })) }))),
      concepts: asJSON(concepts.map(reviewRecord)), facts: asJSON(facts.map(reviewRecord)), connections: asJSON(affected.filter(e => e.record.kind === "connection").map(e => reviewRecord(e.record))),
      existingConnections: asJSON([...saved, ...entries.filter(e => e.selected).map(e => e.record)].filter(r => r.kind === "connection" && !r.isRetired && (endpointIDs.has(r.fields.fromConceptID) || endpointIDs.has(r.fields.toConceptID)) && !affected.some(e => e.record.id === r.id)).map(reviewRecord)),
      protectedEntryIDs: affected.filter(e => e.record.protectedFields.length).map(e => e.record.id), passages: asJSON(window), hasEarlierSource: window.length < passages.length, hasLaterSource: window.length < passages.length, validationFeedback: [] };
    const mergeDecisions = entries.filter(e => endpointIDs.has(e.record.id) && e.acceptMerge && e.mergeTargetID).map(e => ({ conceptID: e.record.id, canonicalID: e.mergeTargetID! }));
    const requestInput = { ...input, mergeDecisions };
    if (Buffer.byteLength(JSON.stringify(requestInput)) > 120_000) throw new DomainError("INVALID_REVIEW_CONTEXT", "Source review needs a smaller group of entries. Unverified suggestions remain unselected.");
    const supplied = new Set(window.map(p => p.sourceID + "/" + p.id));
    const result = await structured(ai, job.userId, requireValue(job.selection), "source_review", policies.review_instructions.replace("\\(ImportSchemas.sourceFidelityPolicy)", policies.import_sourceFidelityPolicy) + inferredInstructions,
      requestInput as JSONObject, z.strictObject({ decisions: z.strictObject(Object.fromEntries(pending.map(i => [i.id, decisions[i.id]!])) ) }), signal, true, 3, undefined, value => {
        for (const issue of pending) {
          const verdict = verdictSchema.parse(value.decisions[issue.id]);
          if (verdict.needsMoreContext || verdict.disposition === "needsReview") continue;
          if (!verdict.evidence.length) throw new DomainError("INVALID_REVIEW", "Supported source reviews require exact evidence.");
          if (verdict.disposition === "supported" && (verdict.missingFacts.length || Object.values(verdict.repairs).some(fields => Object.values(fields).some(v => v !== null)))) throw new DomainError("INVALID_REVIEW", "Supported must not repair entries or add facts.");
          if (issue.passageID && (!verdict.passageAssessment || !verdict.evidence.some(ref => ref.sourceID === sourceID && ref.segmentID === issue.passageID))) throw new DomainError("INVALID_REVIEW", "Assess and cite the reviewed passage explicitly.");
          for (const ref of [...verdict.evidence, ...verdict.missingFacts.flatMap(f => f.evidence)]) {
            const key = ref.sourceID + "/" + ref.segmentID, original = originals.get(key);
            const normalize = (s: string) => s.normalize("NFKC").replace(/\u00ad/g, "").replace(/\s+/g, " ").trim();
            if ((!issue.inferred && ref.sourceID !== sourceID) || !supplied.has(key) || !original || !normalize(ref.quote) || !normalize(original).includes(normalize(ref.quote))) throw new DomainError("INVALID_REVIEW", "Cite an exact quotation from the supplied original passages and sourceID.");
          }
        }
      });
    for (const issue of pending) { const verdict = verdictSchema.parse(result.decisions[issue.id]); if (!verdict.needsMoreContext) results.set(issue.id, verdict); }
  }
  return results;
}
