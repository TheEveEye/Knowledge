import { z } from "zod";
const text = z.string().min(1), nullable = z.string().nullable(), option = z.strictObject({ id: text, text });
export const answerInputSchema = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("text") }),
  z.strictObject({ kind: z.literal("choice"), options: z.array(option).min(3).max(5), correctOptionID: text }),
  z.strictObject({ kind: z.literal("number"), unit: z.string(), expectedValue: z.number(), tolerance: z.number().nonnegative() }),
  z.strictObject({ kind: z.literal("slider"), unit: z.string(), expectedValue: z.number(), tolerance: z.number().nonnegative(), minimum: z.number(), maximum: z.number(), step: z.number().positive() }),
  z.strictObject({ kind: z.literal("ordering"), options: z.array(option).min(3).max(6), correctOrder: z.array(text).min(3).max(6) }),
  z.strictObject({ kind: z.literal("matching"), options: z.array(option).min(4).max(10), matches: z.array(z.strictObject({ leftID: text, rightID: text, criterionID: text })).min(2).max(5) }),
]);
export const criterionSchema = z.strictObject({ id: text, unitKey: text, point: text, givenQuote: z.string(), requiredMeaning: text, requestedPart: text, evidenceIDs: z.array(text).min(1).max(6), acceptedExamples: z.array(text).min(1).max(3) });
export const questionSchema = z.strictObject({
  goal: z.enum(["definition", "explanation", "scalarQuantity", "distinction", "sequence", "association"]), practiceValue: z.enum(["substantive", "organizational"]),
  kind: z.enum(["focused", "integrated", "connection"]), facet: text, prompt: text, givenContext: z.string(), expectedAnswer: text,
  criteria: z.array(criterionSchema).min(1).max(6), acceptableWording: z.string(), input: answerInputSchema,
  precisionNotes: z.array(z.strictObject({ id: text, unitKey: text, text, evidenceIDs: z.array(text) })),
});
export type Question = z.infer<typeof questionSchema> & { id: string; verified: boolean; verification?: Record<string, unknown> };
export const bankSchema = z.strictObject({ questions: z.array(questionSchema), blocked: z.array(z.strictObject({ key: text, reason: text })) });
export const learningPlanSchema = z.strictObject({ disposition: z.enum(["practice", "context", "duplicate", "sourceIssue"]), objective: z.string(), essentialMeanings: z.array(text).max(6), contextualMeanings: z.array(text).max(4), optionalPrecision: z.array(text).max(4), reason: text, evidenceQuotes: z.array(text).min(1).max(3), equivalentKey: nullable });
export function keyed<T extends z.ZodType>(keys: string[], value: T) { return z.strictObject(Object.fromEntries(keys.map(key => [key, value]))); }
export function verificationSchema(question: Question, unitKeys: string[]) {
  const ids = question.criteria.map(c => c.id), byCriterion = <T extends z.ZodType>(schema: T) => keyed(ids, schema);
  const pairs = question.input.kind === "matching" ? question.input.matches : [];
  return z.strictObject({
    issues: z.array(z.strictObject({ gate: text, basis: text, problem: text, counterexample: z.string(), repair: text })),
    omitPrecisionNoteIDs: z.array(text), practiceValue: z.enum(["substantive", "organizational"]), promptRepair: nullable, optionalCriteriaRequested: z.boolean(),
    disclosures: z.array(z.strictObject({ materialID: text, visibleQuotes: z.array(text).min(1).max(3), evidenceQuotes: z.array(text).min(1).max(3), necessary: z.boolean(), reason: text })).max(4),
    quality: z.strictObject({ objective: text, combination: z.enum(["single", "contrast", "relationship", "bundle"]), comparisonAxis: z.string(), integrationBenefit: z.string(), focused: z.boolean(), usefulRetrieval: z.boolean(), cueSafe: z.boolean(), reason: text, manageable: z.boolean(), meaningfulCues: z.boolean(), singleTargetCoherent: z.boolean() }),
    matchingAnswers: keyed(pairs.map(p => p.leftID), z.array(text)), matchingDimensions: keyed(pairs.map(p => p.leftID), z.enum(["definition", "effect", "mechanism", "role", "quantity", "sequence", "classification", "example", "name", "analogy"])),
    scopeCheck: z.strictObject({ alternativeAnswer: z.string(), validUnderPrompt: z.boolean(), coveredByRubric: z.boolean(), sourceSupported: z.boolean(), supportingQuotes: z.array(text).max(3) }),
    contextualAnswers: byCriterion(text), requiredMeanings: byCriterion(text), independentParts: byCriterion(z.array(text).min(1).max(6)), acceptedAnswers: byCriterion(z.array(text).min(1).max(3)),
    promptGivens: byCriterion(z.array(text).max(4)), criterionSupport: byCriterion(z.strictObject({ supported: z.boolean(), reason: text })),
    criterionEssentials: byCriterion(z.strictObject({ essential: z.boolean(), reason: text })),
    coverage: keyed(unitKeys, z.strictObject({ status: z.enum(["complete", "partial", "none"]), missingParts: z.array(text), reason: text })), creditSubjects: keyed(unitKeys, z.array(text).min(1).max(4)),
  });
}
export const judgmentDecision = z.strictObject({ status: z.enum(["met", "partial", "missing"]), evidenceQuotes: z.array(text).max(3), missingMeaning: nullable, completionTurn: z.number().int().nonnegative().nullable() });
export const extraDecisionSchema = (ids: string[]) => z.strictObject({ contextConsistent: z.boolean(), decisions: keyed(ids, judgmentDecision) });
export function judgmentSchema(ids: string[], allowFollowUp: boolean, extras: { key: string; criteria: { id: string }[] }[] = []) {
  const followUp = z.strictObject({ prompt: text, kind: z.enum(["clarification", "furtherAssessment", "hint"]), criterionID: text, interpretations: z.array(text), input: answerInputSchema.nullable() });
  return z.strictObject({ taskFairness: z.strictObject({ status: z.enum(["fair", "ambiguous", "answerGiven"]), reason: nullable, alternativeAnswer: nullable }), additionalRecall: z.strictObject(Object.fromEntries(extras.map(e => [e.key, extraDecisionSchema(e.criteria.map(c => c.id))]))),
    creditRetractions: z.array(z.strictObject({ criterionID: text, reason: text })), interpretedAnswer: text.max(1200), decisions: keyed(ids, judgmentDecision), ambiguities: keyed(ids, z.array(text).max(2)),
    contradictions: z.array(text.max(1500)).max(6), feedback: text.max(3000), followUp: allowFollowUp ? followUp.nullable() : z.null(), sourceConcern: nullable, sourceConcernEvidence: z.array(text).max(2) });
}
