import type { JSONObject, JSONValue } from "@knowledge/contracts";
import { canonical, DomainError, jsonArray, jsonObject, stringValue } from "./core.js";
import { answerInputSchema, type Question } from "./recall-contracts.js";
type Input = Question["input"];
export function renderAnswer(input: Input, value: JSONValue, text: string): string {
  if (input.kind === "text") return text;
  const invalid = () => new DomainError("INVALID_ANSWER", "Complete this question using its displayed answer control.");
  if (input.kind === "number" || input.kind === "slider") {
    if (typeof value !== "number" || !Number.isFinite(value) || input.kind === "slider" && (value < input.minimum || value > input.maximum)) throw invalid();
    return `${value} ${input.unit}`.trim();
  }
  const labels = new Map(input.options.map(o => [o.id, o.text]));
  if (input.kind === "choice") { if (typeof value !== "string" || !labels.has(value)) throw invalid(); return labels.get(value)!; }
  if (input.kind === "ordering") { const order = jsonArray(value); if (canonical([...order].sort()) !== canonical([...labels.keys()].sort())) throw invalid(); return order.map(id => labels.get(stringValue(id))).join(" → "); }
  const pairs = jsonObject(value), expectedLeft = input.matches.map(m => m.leftID).sort(), expectedRight = input.matches.map(m => m.rightID).sort();
  if (canonical(Object.keys(pairs).sort()) !== canonical(expectedLeft) || canonical(Object.values(pairs).sort()) !== canonical(expectedRight)) throw invalid();
  return input.matches.map(m => `${labels.get(m.leftID)} → ${labels.get(stringValue(pairs[m.leftID]))}`).join("; ");
}
export function objectiveAssessment(question: Question, episode: JSONObject): JSONObject | null {
  const turns = jsonArray(episode.turns).map(jsonObject), last = turns[turns.length - 1]; if (!last?.input) return null;
  const input = answerInputSchema.parse(last.input); if (input.kind === "text") return null;
  const assessments = jsonArray(episode.assessments), previous = assessments.length ? jsonObject(assessments[assessments.length - 1]) : {}, decisions = structuredClone(jsonObject(previous.decisions ?? {}));
  for (const criterion of question.criteria) decisions[criterion.id] ??= { status: "missing", missingMeaning: criterion.requiredMeaning, completionTurn: null, evidenceQuotes: [] };
  const value = last.inputValue ?? null, index = turns.length - 1, follow = jsonObject(previous.followUp ?? {}), ids = turns.length === 1 ? question.criteria.map(c => c.id) : [stringValue(follow.criterionID)];
  let correct: boolean;
  if (input.kind === "choice") correct = value === input.correctOptionID;
  else if (input.kind === "number" || input.kind === "slider") correct = typeof value === "number" && Math.abs(value - input.expectedValue) <= input.tolerance + Math.max(1, Math.abs(input.expectedValue)) * 1e-10;
  else if (input.kind === "ordering") correct = canonical(value) === canonical(input.correctOrder);
  else {
    const pairs = jsonObject(value);
    for (const id of new Set(input.matches.map(m => m.criterionID))) {
      const met = input.matches.filter(m => m.criterionID === id).every(m => pairs[m.leftID] === m.rightID), criterion = question.criteria.find(c => c.id === id);
      if (!criterion) throw new DomainError("INVALID_ANSWER", "This control references an unavailable criterion.");
      decisions[id] = { status: met ? "met" : "missing", missingMeaning: met ? null : criterion.requiredMeaning, completionTurn: met ? index : null, evidenceQuotes: [stringValue(last.answer).slice(0, 400)] };
    }
    correct = Object.values(decisions).every(d => jsonObject(d).status === "met");
  }
  if (input.kind !== "matching") for (const id of ids) {
    const criterion = question.criteria.find(c => c.id === id); if (!criterion) throw new DomainError("INVALID_ANSWER", "This control references an unavailable criterion.");
    const prior = jsonObject(decisions[id]);
    decisions[id] = { status: correct ? "met" : "missing", missingMeaning: correct ? null : criterion.requiredMeaning, completionTurn: correct ? prior.status === "met" ? prior.completionTurn ?? index : index : null, evidenceQuotes: [stringValue(last.answer).slice(0, 400)] };
  }
  const all = Object.values(decisions).map(jsonObject), outcome = all.every(d => d.status === "met") ? "correct" : all.some(d => ["met", "partial"].includes(stringValue(d.status))) ? "partial" : "incorrect";
  return { taskFairness: { status: "fair", reason: null, alternativeAnswer: null }, decisions, ambiguities: Object.fromEntries(question.criteria.map(c => [c.id, []])), contradictions: [], feedback: outcome === "correct" ? "Correct." : outcome === "partial" ? "Some parts match. Review the remaining points below." : "That does not match the saved answer. Review it below.", interpretedAnswer: last.answer ?? "", followUp: null, sourceConcern: null, sourceConcernEvidence: [], additionalRecall: {}, creditRetractions: [], outcome, model: "server:structured-answer-v1" };
}
