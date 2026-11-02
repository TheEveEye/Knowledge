import type { JSONObject, JSONValue, SourcePassage } from "@knowledge/contracts";
import { DomainError, jsonArray, jsonObject, stringValue } from "./core.js";

export interface SourceBatch { index: number; required: SourcePassage[]; segments: SourcePassage[] }

/** Preserve the production native 4,000-character / 24-passage budget, including preceding context. */
export function sourceBatches(passages: SourcePassage[], legacy = false): SourceBatch[] {
  const result: SourceBatch[] = []; let required: SourcePassage[] = [], size = 0, previous: SourcePassage | undefined;
  const emit = () => {
    if (!required.length) return;
    result.push({ index: result.length, required, segments: previous ? [previous, ...required] : required });
    previous = required.at(-1); required = []; size = legacy ? 0 : Array.from(previous!.text).length;
  };
  for (const passage of passages) {
    const length = legacy ? passage.text.length : Array.from(passage.text).length;
    if (required.length && (size + length > (legacy ? 12_000 : 4_000) || (!legacy && required.length >= 24))) emit();
    required.push(passage); size += length;
  }
  emit(); return result;
}

export function plannedBatches(passages: SourcePassage[], checkpoint: JSONObject): SourceBatch[] {
  const saved = jsonArray(checkpoint.batchPlan);
  if (!saved.length) return sourceBatches(passages, Object.keys(jsonObject(checkpoint.batches ?? {})).length > 0);
  const owned = saved.flatMap(value => jsonArray(jsonObject(value).requiredSegmentIDs).map(stringValue));
  if (JSON.stringify(owned) !== JSON.stringify(passages.map(p => p.id))) throw new DomainError("INVALID_CHECKPOINT", "The saved batch plan does not match this source. Your accepted work is kept.");
  const byID = new Map(passages.map(p => [p.id, p]));
  return saved.map((value, index) => {
    const ids = jsonArray(jsonObject(value).requiredSegmentIDs).map(stringValue);
    const required = ids.map(id => byID.get(id));
    if (!ids.length || required.some(p => !p)) throw new DomainError("INVALID_CHECKPOINT", "Saved import passages are unavailable. Your accepted work is kept.");
    const first = passages.findIndex(p => p.id === ids[0]);
    return { index, required: required as SourcePassage[], segments: passages.slice(Math.max(0, first - 1), first + required.length) };
  });
}

export const batchPlan = (batches: SourceBatch[]): JSONValue[] => batches.map(batch => ({ index: batch.index, requiredSegmentIDs: batch.required.map(p => p.id) }));

export function extractionProgress(passages: SourcePassage[], batches: SourceBatch[], checkpoint: JSONObject, live: ReadonlyMap<number, JSONObject> = new Map()): JSONObject {
  const saved = jsonObject(checkpoint.batches ?? {}), completed = batches.filter(b => !!saved[String(b.index)]).length;
  const active = [...live.values()].filter(b => b.state === "active");
  return {
    stage: "extracting", activity: active.some(b => b.activity === "receiving") ? "receiving" : active.length ? "processing" : completed ? "saved" : "waiting",
    receivedCharacters: [...live.values()].reduce((sum, b) => sum + (typeof b.receivedCharacters === "number" ? b.receivedCharacters : 0), 0),
    completed, total: batches.length, extractionCompleted: completed, extractionTotal: batches.length, lastActivityAt: new Date().toISOString(),
    sourceSections: sourceSections(passages, batches),
    batches: batches.map(b => {
      const current = live.get(b.index) ?? {};
      const entries = jsonArray(jsonObject(saved[String(b.index)] ?? {}).entries).map(jsonObject), records = entries.map(e => jsonObject(e.record));
      return { index: b.index, state: saved[String(b.index)] ? "checked" : current.state ?? "queued", location: batchLocation(b),
        activity: current.activity ?? "waiting", attempt: current.attempt ?? 1, error: current.error ?? null,
        counts: { concepts: records.filter(r => r.kind === "concept").length, facts: records.filter(r => r.kind === "fact").length, connections: records.filter(r => r.kind === "connection").length },
        concepts: saved[String(b.index)] ? entries.filter(e => jsonObject(e.record).kind === "concept").slice(0, 3).map(e => {
          const record = jsonObject(e.record), fields = jsonObject(record.fields);
          return { id: record.id!, name: fields.name!, segmentIDs: jsonArray(fields.evidence).map(e => jsonObject(e).segmentID ?? ""), checked: true, reviewReason: e.reviewReason ?? null };
        }) : jsonArray(current.previewConcepts) };
    }),
  };
}

export function batchLocation(batch: SourceBatch) {
  const sections = batch.required.map(p => p.section).filter((s): s is string => !!s);
  const pages = batch.required.map(p => p.page).filter((p): p is number => p !== null);
  const parts: string[] = [];
  if (sections.length) parts.push(sections[0] === sections.at(-1) ? sections[0]! : `${sections[0]} – ${sections.at(-1)}`);
  if (pages.length) parts.push(pages[0] === pages.at(-1) ? `Page ${pages[0]}` : `Pages ${pages[0]}–${pages.at(-1)}`);
  return parts.join(" · ").slice(0, 240) || null;
}

export function batchContext(batch: SourceBatch, passages: SourcePassage[], charactersPerSide: number): SourcePassage[] {
  let lower = passages.findIndex(p => p.id === batch.segments[0]!.id), upper = passages.findIndex(p => p.id === batch.required.at(-1)!.id) + 1;
  let before = 0, after = 0, bytes = Buffer.byteLength(JSON.stringify(passages.slice(lower, upper)));
  let left = true, right = true;
  while (left || right) {
    if (left) {
      const p = passages[lower - 1], cost = p ? Buffer.byteLength(JSON.stringify(p)) + 1 : 0;
      if (p && before < charactersPerSide && bytes + cost <= 128_000) { lower--; before += Array.from(p.text).length; bytes += cost; } else left = false;
    }
    if (right) {
      const p = passages[upper], cost = p ? Buffer.byteLength(JSON.stringify(p)) + 1 : 0;
      if (p && after < charactersPerSide && bytes + cost <= 128_000) { upper++; after += Array.from(p.text).length; bytes += cost; } else right = false;
    }
  }
  return passages.slice(lower, upper);
}

export function sourceSections(passages: SourcePassage[], batches: SourceBatch[]): JSONValue[] {
  const headings = passages.some(p => p.section?.trim()), pages = [...new Set(passages.flatMap(p => p.page === null ? [] : [p.page]))].sort((a, b) => a - b);
  const sections = new Map<string, { id: string; title: string; segmentIDs: string[]; batchIndices: number[] }>();
  const owners = new Map(batches.flatMap(b => b.required.map(p => [p.id, b.index] as const)));
  passages.forEach((p, index) => {
    let key: string, title: string;
    if (headings) { title = p.section?.replace(/^#+\s*/, "").trim() || "Opening notes"; key = "heading:" + title; }
    else if (p.page !== null) {
      const bucket = Math.floor(pages.indexOf(p.page) * Math.min(6, pages.length) / pages.length);
      const group = pages.filter((_, i) => Math.floor(i * Math.min(6, pages.length) / pages.length) === bucket);
      key = "page:" + bucket; title = group.length > 1 ? `Pages ${group[0]}–${group.at(-1)}` : `Page ${p.page}`;
    } else { const part = Math.floor(index * Math.min(6, batches.length) / passages.length); key = "part:" + part; title = batches.length <= 1 ? "Your notes" : `Part ${part + 1}`; }
    let section = sections.get(key);
    if (!section) { section = { id: p.id, title, segmentIDs: [], batchIndices: [] }; sections.set(key, section); }
    section.segmentIDs.push(p.id);
    const owner = owners.get(p.id); if (owner !== undefined && !section.batchIndices.includes(owner)) section.batchIndices.push(owner);
  });
  return [...sections.values()];
}

/** Read complete concept objects from a partial JSON array; previews never become accepted draft data. */
export function streamedConcepts(text: string): JSONObject[] {
  const match = /"concepts"\s*:\s*\[/.exec(text); if (!match) return [];
  const result: JSONObject[] = []; let start = -1, depth = 0, quoted = false, escaped = false;
  for (let i = match.index + match[0].length; i < text.length && result.length < 6; i++) {
    const char = text[i];
    if (quoted) { if (escaped) escaped = false; else if (char === "\\") escaped = true; else if (char === '"') quoted = false; continue; }
    if (char === '"') { quoted = true; continue; }
    if (char === "{" || char === "[") { if (!depth) start = i; depth++; }
    else if (char === "}" || char === "]") {
      if (!depth) break;
      depth--;
      if (!depth && start >= 0) {
        try { const value = jsonObject(JSON.parse(text.slice(start, i + 1))); if (typeof value.name === "string") result.push(value); } catch { /* An incomplete object is never a preview. */ }
        start = -1;
      }
    }
  }
  return result;
}
