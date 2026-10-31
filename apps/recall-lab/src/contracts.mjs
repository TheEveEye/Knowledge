import { obj, keyed, list, text, num, bool, choice, nullable } from './core.mjs';
export const criterion = obj({ id: text, unitKey: text, point: text, givenQuote: text, requiredMeaning: text, requestedPart: text, evidenceIDs: list(text, 1, 6), acceptedExamples: list(text, 1, 3) });
export const input = { anyOf: [obj({ kind: choice(['text']) }), obj({ kind: choice(['number']), unit: text, expectedValue: num, tolerance: num }),
  obj({ kind: choice(['choice']), options: list(obj({ id: text, text }), 3, 5), correctOptionID: text })] };
export const question = obj({ goal: choice(['definition', 'explanation', 'association', 'distinction', 'scalarQuantity', 'sequence']), practiceValue: choice(['substantive', 'organizational']),
  kind: choice(['focused', 'integrated', 'connection']), facet: text, prompt: text, givenContext: text, expectedAnswer: text,
  criteria: list(criterion, 1, 6), acceptableWording: text, input,
  precisionNotes: list(obj({ id: text, unitKey: text, text, evidenceIDs: list(text, 1, 6) }), 0, 3) });
export const bank = obj({ questions: list(question, 0, 6), blocked: list(obj({ key: text, reason: text })) });
export const facts = obj({ units: list(obj({ concept: text, statement: text, qualifications: text, evidenceQuote: text }), 0, 3) });
export const plan = obj({ disposition: choice(['practice', 'context', 'duplicate', 'sourceIssue']), objective: text, essentialMeanings: list(text, 0, 6), contextualMeanings: list(text, 0, 4),
  optionalPrecision: list(text, 0, 4), reason: text, evidenceQuotes: list(text, 1, 3), equivalentKey: nullable(text) });
const issue = obj({ gate: choice(['support', 'answerability', 'leakage', 'rubric', 'input', 'mapping']), basis: choice(['source', 'task', 'format', 'scope', 'presentation']), problem: text, counterexample: text, repair: text });
export function verification(q) {
  const ids = q.criteria.map(c => c.id); const mids = [...new Set(q.criteria.map(c => c.unitKey))];
  return obj({ reviews: keyed([q.designID], obj({ issues: list(issue), omitPrecisionNoteIDs: list(text), practiceValue: choice(['substantive', 'organizational']), promptRepair: nullable(text), optionalCriteriaRequested: bool,
    disclosures: list(obj({ materialID: text, visibleQuotes: list(text, 1, 3), evidenceQuotes: list(text, 1, 3), necessary: bool, reason: text }), 0, 4),
    quality: obj({ objective: text, combination: choice(['single', 'contrast', 'relationship', 'bundle']), comparisonAxis: text, integrationBenefit: text, focused: bool, usefulRetrieval: bool, cueSafe: bool, reason: text, manageable: bool, meaningfulCues: bool, singleTargetCoherent: bool }),
    matchingAnswers: obj({}), matchingDimensions: obj({}), scopeCheck: obj({ alternativeAnswer: text, validUnderPrompt: bool, coveredByRubric: bool, sourceSupported: bool, supportingQuotes: list(text, 0, 3) }),
    contextualAnswers: keyed(ids, text), requiredMeanings: keyed(ids, text), independentParts: keyed(ids, list(text, 1, 6)), acceptedAnswers: keyed(ids, list(text, 1, 3)), promptGivens: keyed(ids, list(text, 0, 4)),
    criterionSupport: keyed(ids, obj({ supported: bool, reason: text })), criterionEssentials: keyed(ids, obj({ essential: bool, reason: text })),
    coverage: keyed(mids, obj({ status: choice(['complete', 'partial', 'none']), missingParts: list(text), reason: text })), creditSubjects: keyed(mids, list(text, 1, 4)) })) });
}
export function grading(q, turns, permitFollowUp = true) {
  const ids = q.criteria.map(c => c.id);
  const part = obj({ status: choice(['met', 'partial', 'missing']), evidenceQuotes: list(text, 0, 3), missingMeaning: nullable(text), completionTurn: { enum: [...turns.map((_, i) => i), null] } });
  return obj({ taskFairness: obj({ status: choice(['fair', 'ambiguous', 'answerGiven']), reason: nullable(text), alternativeAnswer: nullable(text) }),
    additionalRecall: obj({}), creditRetractions: list(obj({ criterionID: choice(ids), reason: text })), interpretedAnswer: text, decisions: keyed(ids, part), ambiguities: keyed(ids, list(text, 0, 2)),
    contradictions: list(text, 0, 6), feedback: text, followUp: permitFollowUp ? nullable(obj({ prompt: text, kind: choice(['clarification', 'furtherAssessment', 'hint']), criterionID: choice(ids), input: { type: 'null' }, interpretations: list(text, 0, 2) })) : { type: 'null' },
    sourceConcern: nullable(text), sourceConcernEvidence: list(text, 0, 2) });
}
export const audit = obj({ falseAcceptance: bool, falseRejection: bool, needlessFollowUp: bool, answerLeakage: bool, questionUnfair: bool, feedbackMisleading: bool, evidenceInvalid: bool, severity: choice(['none', 'minor', 'major']), reason: text, generalRule: text });
