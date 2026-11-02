import { z } from "zod";
import type { JSONObject, JSONValue, LibraryEntity } from "@knowledge/contracts";
import { AIService } from "./ai.js";
import { canonical, DomainError, hash, jsonArray, jsonObject, normalizeName, requireValue, stringValue } from "./core.js";
import { JobQueue, type ClaimedJob } from "./jobs.js";
import { policies } from "./policies.js";
import { asJSON, proposalSchema, structured } from "./structured.js";

const stop = new Set("the and for are with that this from their which can may have has into such other during they these notes described about than also".split(" "));
const key = (r: LibraryEntity) => r.kind + "/" + r.id;
function examples(record: LibraryEntity, records: LibraryEntity[]) {
  const descendants = new Set([record.id]);
  for (let i = 0; i < 3; i++) for (const r of records) if (r.kind === "topic" && descendants.has(stringValue(r.fields.parentID))) descendants.add(r.id);
  const ids = new Set(records.filter(r => r.kind === "placement" && descendants.has(stringValue(r.fields.topicID))).map(r => r.fields.conceptID));
  return records.filter(r => !r.isRetired && (r.kind === "concept" && ids.has(r.id) || r.kind === "topic" && descendants.has(r.id) && r.id !== record.id)).map(r => stringValue(r.fields.name)).slice(0, 24);
}
function entry(record: LibraryEntity, records: LibraryEntity[]) {
  const title = stringValue(record.fields.name ?? record.fields.statement ?? record.fields.explanation), context = record.kind === "topic" ? examples(record, records) : [];
  return { key: key(record), id: record.id, kind: record.kind, name: title.slice(0, 1200), explanation: stringValue(record.fields.explanation ?? record.fields.statement).slice(0, 1600), aliases: jsonArray(record.fields.aliases).slice(0, 8), qualifications: stringValue(record.fields.qualifications).slice(0, 800), relationship: stringValue(record.fields.kind), parent: stringValue(records.find(r => r.id === record.fields.parentID)?.fields.name), parentID: record.fields.parentID ?? null, namingNote: record.fields.resolutionSuggestion ?? null, examples: context.slice(0, 12), evidence: jsonArray(record.fields.evidence).slice(0, 4).map(e => ({ ...jsonObject(e), quote: stringValue(jsonObject(e).quote).slice(0, 1600) })) };
}
function terms(record: LibraryEntity, records: LibraryEntity[]) {
  const text = [record.fields.name, record.fields.statement, record.fields.explanation, ...jsonArray(record.fields.aliases), ...(record.kind === "topic" ? examples(record, records) : [])].filter(v => typeof v === "string").join(" ");
  return new Set((normalizeName(text).match(/[\p{L}\p{N}]+/gu) ?? []).filter(w => w.length > 2 && !stop.has(w)));
}
const resultSchema = z.strictObject({ decisions: z.array(z.strictObject({ incomingKey: z.string(), existingKey: z.string(), disposition: z.enum(["equivalent", "distinct", "unresolved"]), reason: z.string().min(1) })), updates: z.array(proposalSchema) });
export async function semanticUpdates(ai: AIService, queue: JobQueue, job: ClaimedJob, subject: string, base: LibraryEntity[], current: LibraryEntity[], incoming: LibraryEntity[], checkpoint: JSONObject, signal: AbortSignal) {
  const baseMap = new Map(base.map(r => [r.id, r])), kinds = ["concept", "fact", "connection", "topic"];
  const changed = current.filter(r => !r.isRetired && kinds.includes(r.kind) && canonical(baseMap.get(r.id) ?? null) !== canonical(r));
  const all = [...current, ...incoming], groups = incoming.filter(r => kinds.includes(r.kind) && !r.isRetired && !r.fields.keepSeparate && !r.protectedFields.length).sort((a, b) => key(a).localeCompare(key(b))).flatMap(record => {
    const tokens = terms(record, all), candidates = changed.filter(c => c.kind === record.kind && c.id !== record.id).map(c => ({ record: c, score: [...terms(c, current)].filter(t => tokens.has(t)).length })).filter(c => c.score > 0).sort((a, b) => b.score - a.score || key(a.record).localeCompare(key(b.record))).slice(0, 6).map(c => c.record);
    return candidates.length ? [{ incoming: record, candidates }] : [];
  });
  const saved = jsonObject(checkpoint.semanticBatches ?? {}), merges: { incomingID: string; existingID: string; reason: string }[] = [], updates: JSONValue[] = [];
  for (let offset = 0; offset < groups.length; offset += 4) {
    const batch = groups.slice(offset, offset + 4), records = batch.flatMap(g => [g.incoming, ...g.candidates]), ids = new Set(records.map(r => r.id)), concepts = new Set(records.filter(r => r.kind === "concept").map(r => r.id)), supporting = new Set(records.flatMap(r => jsonArray(r.fields.supportingFactIDs)));
    const facts = all.filter(r => r.kind === "fact" && !r.isRetired && (ids.has(r.id) || concepts.has(stringValue(r.fields.conceptID)) || supporting.has(r.id))).slice(0, 80);
    const input = { subject, groups: batch.map(g => ({ incoming: entry(g.incoming, all), candidates: g.candidates.map(c => entry(c, current)) })), supportingFacts: facts.map(f => entry(f, all)) };
    if (Buffer.byteLength(JSON.stringify(input)) > 120_000) throw new DomainError("SEMANTIC_CONTEXT_LIMIT", "These updates need a smaller group of notes. Your draft was kept.");
    const signature = hash({ policy: "subject-updates-v2", input });
    const result = saved[signature] ? resultSchema.parse(saved[signature]) : await structured(ai, job.userId, requireValue(job.selection), "subject_updates", policies.merge_instructions, asJSON(input) as JSONObject, resultSchema, signal, true, 1);
    const pairs = new Set(batch.flatMap(g => g.candidates.map(c => key(g.incoming) + "|" + key(c)))), answered = new Set<string>();
    for (const decision of result.decisions) { const pair = decision.incomingKey + "|" + decision.existingKey; if (!pairs.has(pair) || answered.has(pair)) throw new DomainError("INVALID_RECONCILIATION", "A semantic decision references unavailable or repeated material."); answered.add(pair); }
    if (answered.size !== pairs.size) throw new DomainError("INVALID_RECONCILIATION", "Some semantic decisions were missing. Your draft was kept.");
    for (const group of batch) {
      const targets = result.decisions.filter(d => d.incomingKey === key(group.incoming) && d.disposition === "equivalent").map(d => ({ record: requireValue(group.candidates.find(c => key(c) === d.existingKey)), reason: d.reason })).sort((a, b) => key(a.record).localeCompare(key(b.record)));
      if (targets[0]) merges.push({ incomingID: group.incoming.id, existingID: targets[0].record.id, reason: targets[0].reason });
    }
    for (const proposal of result.updates) if (ids.has(proposal.entityID) && proposal.supportingFactIDs.every(id => facts.some(f => f.id === id))) updates.push(asJSON(proposal));
    saved[signature] = asJSON(result); checkpoint.semanticBatches = saved;
    await queue.checkpoint(job, checkpoint, { stage: "reconcilingCurrentLibrary", completed: Math.min(offset + 4, groups.length), total: groups.length });
  }
  return { merges, updates };
}
