import type { JSONObject, JSONValue, LibraryEntity } from "@knowledge/contracts";
import { DomainError, hash, jsonArray, jsonObject, stringValue } from "./core.js";
import { asJSON } from "./structured.js";
import type { Question } from "./recall-contracts.js";

// Change the version whenever the executable preparation contract changes, not just its prose.
export const designVersion = "recall-design-v14";
export type DesignUnit = { key: string; materialID: string; entity: LibraryEntity; signature: string; snapshot: JSONObject };
export const evidenceID = (key: string, evidence: JSONValue) => `${key}-e${hash(evidence).slice(0, 20)}`;
export const bounded = (text: string, maximum: number) => text.trim().length > 0 && text.length <= maximum;
const normalize = (text: string) => text.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase().replace(/\s+/g, " ").trim();
export function displayPrompt(prompt: string) {
  const text = prompt.trim().replace(/^according to (?:the )?(?:(?:saved|supplied) )?(?:notes?|claim),\s*/i, "")
    .replace(/,?\s+according to (?:the )?(?:(?:saved|supplied) )?notes?\?$/i, "?");
  return text.charAt(0).toUpperCase() + text.slice(1);
}
export function contextIssue(prompt: string) {
  return !/[:\n"“«]/.test(prompt) && /^(?:\s*(?:in|according to|based on)\s+(?:this|that|the above|the given)\s+(?:definition|passage|text|diagram|example)\b|\s*what\s+(?:does|is)\s+(?:this|that)\s+(?:statistical measure|measure|technique|method|process|definition)\b)/i.test(prompt);
}
export function unitInput(u: DesignUnit, plans: JSONObject = {}) {
  return { key: u.key, materialID: u.materialID, ...u.snapshot, concept: u.snapshot.conceptName,
    learningPlan: plans[u.key] ?? u.snapshot.learningPlan ?? null,
    evidence: jsonArray(u.snapshot.evidence).map(e => ({ id: evidenceID(u.key, e), quote: jsonObject(e).quote ?? "" })) };
}
export function validateDesign(q: Question, units: DesignUnit[], allowed: string[], enrichment = false) {
  const reject = (message: string): never => { throw new DomainError("INVALID_QUESTION", message); };
  q.prompt = displayPrompt(q.prompt);
  const keys = [...new Set(q.criteria.map(c => c.unitKey))];
  if (!bounded(q.prompt, 1600) || !bounded(q.facet, 160) || !bounded(q.expectedAnswer, 4000) || q.givenContext.length > 1600 || q.acceptableWording.length > 2000) reject("Use a bounded prompt and expected meaning.");
  if (keys.length > (enrichment ? 2 : 1) || keys.some(k => !allowed.includes(k))) reject("Assess only the selected targets; coverage requires one complete focused target.");
  if (enrichment && q.input.kind === "text" && (keys.length === 1 || q.criteria.length > 4)) reject("Enrichment must add a useful control or a compact integration, not another standalone text variant.");
  if (new Set(q.criteria.map(c => c.id)).size !== q.criteria.length) reject("Criteria must have unique IDs.");
  for (const c of q.criteria) {
    const unit = units.find(u => u.key === c.unitKey);
    if (!unit || unit.snapshot.reviewNote || jsonObject(unit.snapshot.learningPlan ?? {}).disposition !== "practice") reject("An assessed target has unresolved eligibility or source concerns.");
    const valid = new Set(jsonArray(unit!.snapshot.evidence).map(e => evidenceID(c.unitKey, e)));
    if (!bounded(c.id, 80) || !bounded(c.point, 1200) || !bounded(c.requiredMeaning, 1000) || !bounded(c.requestedPart, 200) || c.givenQuote.length > 600 || c.acceptedExamples.some(a => !bounded(a, 400)) || new Set(c.evidenceIDs).size !== c.evidenceIDs.length || c.evidenceIDs.some(id => !valid.has(id))) reject("Each criterion needs bounded new meaning and evidence from its own target.");
    if (c.givenQuote && !normalize(q.prompt).includes(normalize(c.givenQuote))) c.givenQuote = "";
  }
  q.kind = keys.length > 1 ? "integrated" : units.find(u => u.key === keys[0])?.entity.kind === "connection" ? "connection" : "focused";
  const input = q.input, options = "options" in input ? input.options : [];
  if ([q.prompt, ...options.map(o => o.text)].some(s => /\btheor(?:y|ies)\s+(?:[A-D]|[1-9][0-9]?|[IVX]{1,4})\b/i.test(s))) reject("Use meaningful identifiers rather than outline labels.");
  if (contextIssue(q.prompt)) reject("Name the subject or supply the referenced visible context without revealing the answer.");
  if (new Set(options.map(o => normalize(o.text))).size !== options.length || options.some(o => !bounded(o.id, 40) || !bounded(o.text, 400))) reject("Options must have distinct meanings and bounded labels.");
  if (["choice", "number", "slider", "ordering"].includes(input.kind) && q.criteria.length !== 1) reject("This control requires one criterion; use text or matching for separate response parts.");
  if (input.kind === "matching" && (input.matches.length !== q.criteria.length || new Set(input.matches.map(m => m.criterionID)).size !== q.criteria.length)) reject("Each matching pair must map to exactly one criterion.");
  if ((input.kind === "number" || input.kind === "slider") && !bounded(input.unit, 80)) reject("A numerical answer needs named units.");
  if (input.kind === "slider" && (input.step > input.maximum - input.minimum || (input.maximum - input.minimum) / input.step > 1000 || input.expectedValue <= input.minimum || input.expectedValue >= input.maximum || input.tolerance < input.step / 2)) reject("Use a meaningful slider scale with an attainable tolerance and an interior answer.");
  const noteIDs = new Set(q.criteria.map(c => c.id));
  q.precisionNotes = q.precisionNotes.slice(0, 3).filter(n => {
    const unit = units.find(u => u.key === n.unitKey), valid = new Set(unit ? jsonArray(unit.snapshot.evidence).map(e => evidenceID(n.unitKey, e)) : []);
    if (!keys.includes(n.unitKey) || !bounded(n.id, 80) || noteIDs.has(n.id) || !bounded(n.text, 500) || /\b(?:grader|rubric|criterion|criteria)\b|\b(?:do not|don't|never|must not)\s+(?:require|grade|score|assess|penalize|accept|ask)/i.test(n.text) || !n.evidenceIDs.length || n.evidenceIDs.some(id => !valid.has(id))) return false;
    noteIDs.add(n.id); return true;
  });
  if (Buffer.byteLength(JSON.stringify(q)) > 45_000) reject("Use a smaller question payload.");
}
export function verificationInput(question: Question, units: DesignUnit[], plans: JSONObject) {
  const bound = new Set(question.criteria.map(c => c.unitKey));
  const catalog = units.map(u => ({ id: u.materialID, kind: u.snapshot.kind, concept: u.snapshot.conceptName, aliases: u.snapshot.aliases,
    claim: u.snapshot.statement, qualifications: u.snapshot.qualifications, learningPlan: plans[u.key] ?? u.snapshot.learningPlan ?? null,
    evidence: jsonArray(u.snapshot.evidence).map(e => stringValue(jsonObject(e).quote)).filter((_, i) => bound.has(u.key) || i < 3).map(q => bound.has(u.key) ? q : q.slice(0, 1000)) }));
  const input = question.input;
  const answerKey: JSONObject = { ...asJSON(input) as JSONObject };
  if (input.kind === "matching") answerKey.matches = [];
  if ("options" in input) answerKey.options = [];
  return { questions: [{ designID: question.id,
    visibleTask: { prompt: question.prompt, kind: input.kind, options: "options" in input ? input.options : [], unit: "unit" in input ? input.unit : null,
      minimum: input.kind === "slider" ? input.minimum : null, maximum: input.kind === "slider" ? input.maximum : null, step: input.kind === "slider" ? input.step : null },
    privateRubric: { expectedAnswer: question.expectedAnswer, acceptableWording: question.acceptableWording, givenContext: question.givenContext,
      criteria: question.criteria.map(c => { const unit = units.find(u => u.key === c.unitKey)!; return { ...c,
        sourceEvidenceIndices: jsonArray(unit.snapshot.evidence).flatMap((e, i) => c.evidenceIDs.includes(evidenceID(unit.key, e)) ? [i] : []), additionalEvidence: [] }; }),
      bindings: [...bound].map(key => ({ materialID: key, criterionIDs: question.criteria.filter(c => c.unitKey === key).map(c => c.id) })),
      answerKey, precisionNotes: question.precisionNotes.map(n => ({ id: n.id, materialID: n.unitKey, text: n.text, sourceQuote: n.evidenceIDs.map(id => { const unit = units.find(u => u.key === n.unitKey); const evidence = jsonArray(unit?.snapshot.evidence).find(e => evidenceID(n.unitKey, e) === id); return evidence ? stringValue(jsonObject(evidence).quote) : ""; }).join("\n") })), facet: question.facet, boundary: "", kind: question.kind, goal: question.goal, practiceValue: question.practiceValue } }],
    matchingSets: input.kind === "matching" ? { [question.id]: { left: input.matches.map(m => ({ id: m.leftID, criterionID: m.criterionID })), right: input.matches.map(m => m.rightID) } } : {}, targetCatalog: catalog };
}
export function presentationPriority(q: Question) {
  const review = jsonObject(asJSON(q.verification ?? {})), quality = jsonObject(review.quality), integrated = new Set(q.criteria.map(c => c.unitKey)).size > 1;
  const useful = integrated && ["contrast", "relationship"].includes(stringValue(quality.combination)) && bounded(stringValue(quality.comparisonAxis), 400) && bounded(stringValue(quality.integrationBenefit), 600);
  if (integrated && !useful) return -100;
  return (q.practiceValue === "organizational" ? 0 : 40) + (useful ? 8 : 4) + (q.input.kind === "number" ? 10 : q.input.kind === "text" ? 2 : 0);
}
export function enrichmentSelection(units: DesignUnit[], focus: string[], accepted: Question[]) {
  const scalar = accepted.find(q => q.goal === "scalarQuantity" && q.input.kind === "text" && new Set(q.criteria.map(c => c.unitKey)).size === 1 && !/\b\d+(?:[.,]\d+)?\s*(?:–|—|-|to)\s*\d/.test(q.expectedAnswer + " " + units.find(u => u.key === q.criteria[0]?.unitKey)?.snapshot.statement));
  if (scalar) return { keys: [scalar.criteria[0]!.unitKey], format: "number" as const };
  const claims = units.filter(u => accepted.some(q => q.criteria.length > 0 && q.criteria.every(c => c.unitKey === u.key)) && u.entity.kind === "fact" && !u.snapshot.reviewNote && jsonObject(u.snapshot.learningPlan ?? {}).disposition === "practice");
  const anchor = claims.find(u => focus.includes(u.key));
  if (!anchor) return { keys: [], format: null };
  const words = (s: string) => new Set(normalize(s).split(/[^\p{L}\p{N}]+/u).filter(w => w.length > 2 && !["sleep", "stage", "states", "state", "theory", "theories", "effect", "effects", "the", "and"].includes(w)));
  const names = words(stringValue(anchor.snapshot.conceptName));
  const partner = claims.filter(u => u.key !== anchor.key && normalize(stringValue(u.snapshot.statement)) !== normalize(stringValue(anchor.snapshot.statement))).sort((a, b) => {
    const overlap = (u: DesignUnit) => [...words(stringValue(anchor.snapshot.statement))].filter(w => words(stringValue(u.snapshot.statement)).has(w)).length;
    return overlap(b) - overlap(a) || a.key.localeCompare(b.key);
  }).find(u => [...words(stringValue(u.snapshot.conceptName))].some(w => names.has(w)) || units.some(edge => edge.entity.kind === "connection" && anchor.snapshot.conceptID !== u.snapshot.conceptID && [anchor.snapshot.conceptID, u.snapshot.conceptID].every(id => jsonArray(edge.snapshot.relatedConceptIDs).includes(id!))));
  return { keys: partner ? [anchor.key, partner.key] : [], format: null };
}

// Retry context describes the rejected task without repeating its catalog or reviewer transcript.
export function repairExample(q: Question, units: DesignUnit[]) {
  return { prompt: q.prompt.slice(0, 1000), expectedAnswer: q.expectedAnswer.slice(0, 1500),
    requiredMeanings: q.criteria.slice(0, 8).map(c => c.requiredMeaning.slice(0, 400)), inputKind: q.input.kind,
    boundUnits: Object.fromEntries([...new Set(q.criteria.map(c => c.unitKey))].map(key => [key, units.find(u => u.key === key)?.snapshot.statement ?? ""])),
    criteria: q.criteria, input: q.input };
}
