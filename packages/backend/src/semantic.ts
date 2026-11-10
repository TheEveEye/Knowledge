import { z } from "zod";
import type { JSONObject, JSONValue, LibraryEntity } from "@knowledge/contracts";
import { AIService } from "./ai.js";
import { canonical, DomainError, hash, jsonArray, jsonObject, normalizeName, requireValue, stringValue } from "./core.js";
import { JobQueue, type ClaimedJob } from "./jobs.js";
import { policies } from "./policies.js";
import { asJSON, connectionKinds, factKinds, proposalSchema, structured } from "./structured.js";

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
type SemanticResult = z.infer<typeof resultSchema>;
type Comparison = { incoming: LibraryEntity; candidate: LibraryEntity };
const pairID = (pair: Comparison) => "pair_" + hash([key(pair.incoming), key(pair.candidate)]);
const decisionSchema = z.strictObject({ disposition: z.enum(["equivalent", "distinct", "unresolved"]), reason: z.string().min(1) });
const instructions = policies.merge_instructions + `
The response protocol uses fixed comparison IDs. Return decisions as an object keyed by EVERY
supplied comparisonID, exactly once, with only disposition and reason. Do not return entity keys
or invent comparisons. Each comparison binds one supplied incoming entry to one candidate.
Use unresolved for uncertain meaning; it preserves both entries and is a valid completed comparison.
Updates must reference supplied entity IDs and supporting fact IDs, use fields allowed for that
entity kind, and preserve meaning. Non-topic updates require at least one supporting fact.
Return updates [] when no supported improvement is needed. validationIssues describes protocol
errors to repair, not evidence that any source claim is wrong.`;
export async function semanticUpdates(ai: AIService, queue: JobQueue, job: ClaimedJob, subject: string, base: LibraryEntity[], current: LibraryEntity[], incoming: LibraryEntity[], checkpoint: JSONObject, signal: AbortSignal) {
  const baseMap = new Map(base.map(r => [r.id, r])), kinds = ["concept", "fact", "connection", "topic"];
  const changed = current.filter(r => !r.isRetired && kinds.includes(r.kind) && canonical(baseMap.get(r.id) ?? null) !== canonical(r));
  const all = [...current, ...incoming], groups = incoming.filter(r => kinds.includes(r.kind) && !r.isRetired && !r.fields.keepSeparate && !r.protectedFields.length).sort((a, b) => key(a).localeCompare(key(b))).flatMap(record => {
    const tokens = terms(record, all), candidates = changed.filter(c => c.kind === record.kind && c.id !== record.id).map(c => ({ record: c, score: [...terms(c, current)].filter(t => tokens.has(t)).length })).filter(c => c.score > 0).sort((a, b) => b.score - a.score || key(a.record).localeCompare(key(b.record))).slice(0, 6).map(c => c.record);
    return candidates.length ? [{ incoming: record, candidates }] : [];
  });
  const saved = jsonObject(checkpoint.semanticBatches ?? {}), merges: { incomingID: string; existingID: string; reason: string }[] = [], updates: JSONValue[] = [];
  const splitBatches = jsonObject(checkpoint.semanticSplitBatches ?? {});
  for (let offset = 0; offset < groups.length; offset += 4) {
    const batch = groups.slice(offset, offset + 4), records = batch.flatMap(g => [g.incoming, ...g.candidates]), ids = new Set(records.map(r => r.id)), concepts = new Set(records.filter(r => r.kind === "concept").map(r => r.id)), supporting = new Set(records.flatMap(r => jsonArray(r.fields.supportingFactIDs)));
    const facts = all.filter(r => r.kind === "fact" && !r.isRetired && (ids.has(r.id) || concepts.has(stringValue(r.fields.conceptID)) || supporting.has(r.id))).slice(0, 80);
    const input = { subject, groups: batch.map(g => ({ incoming: entry(g.incoming, all), candidates: g.candidates.map(c => entry(c, current)) })), supportingFacts: facts.map(f => entry(f, all)) };
    const comparisons = batch.flatMap(g => g.candidates.map(candidate => ({ incoming: g.incoming, candidate })));
    const validate = (result: SemanticResult, pairs: Comparison[], supplied: Set<string>, supportingFacts: LibraryEntity[]) => {
      const allowed = new Set(pairs.map(p => key(p.incoming) + "|" + key(p.candidate))), answered = new Set<string>();
      for (const decision of result.decisions) {
        const pair = decision.incomingKey + "|" + decision.existingKey;
        if (!allowed.has(pair) || answered.has(pair)) throw new DomainError("INVALID_RECONCILIATION", "Return exactly one decision for each supplied comparisonID; remove unavailable or repeated comparisons.");
        answered.add(pair);
      }
      if (answered.size !== allowed.size) throw new DomainError("INVALID_RECONCILIATION", "Decisions are missing. Return every supplied comparisonID, using unresolved if meaning is uncertain.");
      const fields: Record<string, string[]> = { concept: ["name", "explanation"], fact: ["statement", "qualifications", "kind"], connection: ["explanation", "kind"], topic: ["name", "parentID"] };
      for (const proposal of result.updates) {
        const target = records.find(r => r.id === proposal.entityID);
        if (!supplied.has(proposal.entityID) || !target || !fields[target.kind]?.includes(proposal.field)
          || (target.kind !== "topic" && !proposal.supportingFactIDs.length)
          || proposal.supportingFactIDs.some(id => !supportingFacts.some(f => f.id === id))
          || (proposal.field === "kind" && !(target.kind === "fact" ? factKinds : connectionKinds).some(kind => kind === proposal.value))
          || (proposal.field === "parentID" && proposal.value !== "" && !records.some(r => supplied.has(r.id) && r.id === proposal.value && r.kind === "topic"))) {
          throw new DomainError("INVALID_RECONCILIATION", "Updates must use supplied entity IDs, allowed fields for their kind, and supplied supporting fact IDs. Non-topic updates need supporting facts. Remove unsupported updates or return updates=[].");
        }
      }
    };
    const solve = async (pairs: Comparison[]): Promise<SemanticResult> => {
      signal.throwIfAborted();
      const supplied = new Set(pairs.flatMap(p => [p.incoming.id, p.candidate.id]));
      const subset = batch.map(g => ({ incoming: entry(g.incoming, all), candidates: g.candidates.filter(c => pairs.some(p => p.incoming.id === g.incoming.id && p.candidate.id === c.id)).map(c => entry(c, current)) })).filter(g => g.candidates.length);
      const supportingFacts = facts.filter(f => supplied.has(f.id) || pairs.some(p => [p.incoming, p.candidate].some(r => r.kind === "concept" && f.fields.conceptID === r.id || jsonArray(r.fields.supportingFactIDs).includes(f.id))));
      const request = { subject, groups: subset, supportingFacts: supportingFacts.map(f => entry(f, all)), comparisons: pairs.map(p => ({ comparisonID: pairID(p), incomingKey: key(p.incoming), existingKey: key(p.candidate) })) };
      const signature = hash({ policy: "subject-updates-v3", instructions, input: request });
      // Retain valid checkpoints from before the protocol change. Never replay a
      // malformed cached response or silently treat it as an unresolved comparison.
      const cached = saved[signature] ?? (pairs.length === comparisons.length ? saved[hash({ policy: "subject-updates-v2", input })] : undefined);
      if (cached) {
        try { const result = resultSchema.parse(cached); validate(result, pairs, supplied, supportingFacts); return result; }
        catch (error) { if (!(error instanceof z.ZodError) && !(error instanceof DomainError && error.code === "INVALID_RECONCILIATION")) throw error; }
      }
      const split = async (): Promise<SemanticResult> => {
        // Persist the split before descending so retries resume accepted children
        // instead of paying to retry their already rejected parent batch.
        splitBatches[signature] = true; checkpoint.semanticSplitBatches = splitBatches;
        await queue.checkpoint(job, checkpoint, { stage: "reconcilingCurrentLibrary", completed: offset, total: groups.length });
        const middle = Math.ceil(pairs.length / 2);
        const left = await solve(pairs.slice(0, middle)), right = await solve(pairs.slice(middle));
        const result = { decisions: [...left.decisions, ...right.decisions], updates: [...left.updates, ...right.updates] };
        saved[signature] = asJSON(result); checkpoint.semanticBatches = saved;
        await queue.checkpoint(job, checkpoint, { stage: "reconcilingCurrentLibrary", completed: offset, total: groups.length });
        return result;
      };
      if (pairs.length > 1 && splitBatches[signature] === true) return split();
      try {
        if (Buffer.byteLength(JSON.stringify(request)) > 120_000) throw new DomainError("SEMANTIC_CONTEXT_LIMIT", "This comparison context is too large.");
        const schema = z.strictObject({ decisions: z.strictObject(Object.fromEntries(pairs.map(p => [pairID(p), decisionSchema]))), updates: z.array(proposalSchema) })
          .transform(value => ({ decisions: pairs.map(p => ({ incomingKey: key(p.incoming), existingKey: key(p.candidate), ...requireValue(value.decisions[pairID(p)]) })), updates: value.updates }));
        const result = await structured(ai, job.userId, requireValue(job.selection), "subject_updates", instructions, asJSON(request) as JSONObject, schema, signal, true, 3, undefined, value => validate(value, pairs, supplied, supportingFacts));
        saved[signature] = asJSON(result); checkpoint.semanticBatches = saved;
        await queue.checkpoint(job, checkpoint, { stage: "reconcilingCurrentLibrary", completed: offset, total: groups.length });
        return result;
      } catch (error) {
        signal.throwIfAborted();
        // Provider/account/lease failures propagate without splitting or starting
        // additional paid work. Only exhausted response validation/context splits.
        if (!(error instanceof DomainError) || !["INVALID_AI_RESPONSE", "SEMANTIC_CONTEXT_LIMIT"].includes(error.code)) throw error;
        if (pairs.length === 1) throw new DomainError(error.code, `Semantic comparison ${pairID(pairs[0]!)} could not be completed. Accepted comparisons and your draft were kept. Retry to continue.`, error.statusCode);
        return split();
      }
    };
    const result = await solve(comparisons);
    for (const group of batch) {
      const targets = result.decisions.filter(d => d.incomingKey === key(group.incoming) && d.disposition === "equivalent").map(d => ({ record: requireValue(group.candidates.find(c => key(c) === d.existingKey)), reason: d.reason })).sort((a, b) => key(a.record).localeCompare(key(b.record)));
      if (targets[0]) merges.push({ incomingID: group.incoming.id, existingID: targets[0].record.id, reason: targets[0].reason });
    }
    for (const proposal of result.updates) if (ids.has(proposal.entityID) && proposal.supportingFactIDs.every(id => facts.some(f => f.id === id))) updates.push(asJSON(proposal));
    await queue.checkpoint(job, checkpoint, { stage: "reconcilingCurrentLibrary", completed: Math.min(offset + 4, groups.length), total: groups.length });
  }
  return { merges, updates };
}
