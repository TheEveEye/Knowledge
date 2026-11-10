import { randomUUID } from "node:crypto";
import { and, asc, desc, eq, gt, inArray, isNull, lte, or, sql } from "drizzle-orm";
import { createEmptyCard, fsrs, Rating, type CardInput, type Grade } from "ts-fsrs";
import { z } from "zod";
import type { AISelection, JSONObject, JSONValue, LibraryEntity, Page, RecallDashboard, RecallMaterialDisplay, RecallProficiency, RecallSession, RecallSessionPresentation, RecallSessionSummary } from "@knowledge/contracts";
import type { Database, Transaction } from "./database.js";
import { AIService } from "./ai.js";
import { DomainError, canonical, completedOperation, expected, hash, heartbeatOperation, invalidate, jsonArray, jsonObject, mutation, ownedSubject, releaseOperation, requireValue, reserveOperation, stringValue } from "./core.js";
import { snapshot } from "./library.js";
import { JobQueue, type ClaimedJob } from "./jobs.js";
import { entities, jobs, learningEvents, recallMaterials, recallSessions, recallTargets, passages } from "./schema.js";
import { asJSON, selectionSchema, structured } from "./structured.js";
import { designBankSchema, extraDecisionSchema, judgmentSchema, keyed, learningPlanSchema, questionSchema, verificationSchema, type Question } from "./recall-contracts.js";
import { policies } from "./policies.js";
import { candidateMatch, candidateQuantities, mentionsSubject } from "./recall-candidates.js";
import { designVersion, bounded, contextIssue, displayPrompt, enrichmentSelection, evidenceID, presentationPriority, repairExample, unitInput, validateDesign, verificationInput } from "./recall-design.js";
import { objectiveAssessment, renderAnswer } from "./recall-objective.js";

export const schedulerVersion = "fsrs6-retention90-no-fuzz-v1", recallPolicyVersion = "recall-evidence-v21";
const scheduler = fsrs({ request_retention: 0.9, enable_fuzz: false, enable_short_term: true, learning_steps: ["1m", "10m"], relearning_steps: ["10m"],
  w: [0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542] });
type Unit = { key: string; materialID: string; entity: LibraryEntity; signature: string; snapshot: JSONObject };
type Session = typeof recallSessions.$inferSelect;
type Target = typeof recallTargets.$inferSelect;
type ExtraCandidate = { key: string; targetID: string; targetVersion: number; signature: string; claim: string; question: Question };
function extraEvidence(value: JSONValue | undefined, candidate: ExtraCandidate, answer: string) {
  const decision = jsonObject(value ?? {}), parts = jsonObject(decision.decisions ?? {});
  return decision.contextConsistent === true && candidate.question.criteria.every(c => {
    const part = jsonObject(parts[c.id] ?? {}), quotes = jsonArray(part.evidenceQuotes);
    return part.status === "met" && part.completionTurn === 0 && part.missingMeaning === null && quotes.length > 0 && quotes.length <= 3 && quotes.every(q => typeof q === "string" && q.trim().length > 0 && q.length <= 400 && answer.includes(q));
  });
}
const sessionDTO = (s: Pick<Session, "id" | "subjectId" | "version" | "finished" | "state" | "updatedAt">): RecallSession => ({ id: s.id, subjectID: s.subjectId, version: s.version, finished: s.finished, state: s.state, updatedAt: s.updatedAt.toISOString() });
function card(memory: JSONObject | null, now: Date): CardInput { return memory ? { ...memory, due: new Date(stringValue(memory.due)), ...(memory.last_review ? { last_review: new Date(stringValue(memory.last_review)) } : {}) } as unknown as CardInput : createEmptyCard(now); }
function verifiedQuestions(target: Target): Question[] { return jsonArray(target.data.questions).map(q => jsonObject(q) as unknown as Question).filter(q => q.verified); }
function normalizedAnswer(answer: string) { return answer.trim().replace(/[?？]+$/u, "").trim(); }
function outcome(judgment: JSONObject): "correct" | "partial" | "incorrect" | "uncertain" {
  const fairness = jsonObject(judgment.taskFairness ?? {});
  if (fairness.status !== "fair" || judgment.sourceConcern) return "uncertain";
  const decisions = Object.values(jsonObject(judgment.decisions ?? {})).map(jsonObject), ambiguities = Object.values(jsonObject(judgment.ambiguities ?? {})).some(a => jsonArray(a).length > 0);
  if (ambiguities) return "partial";
  if (decisions.length && decisions.every(d => d.status === "met") && jsonArray(judgment.contradictions).length === 0) return "correct";
  return decisions.some(d => d.status === "met" || d.status === "partial") ? "partial" : "incorrect";
}
function projectedAssessment(assessment: JSONObject, question: Question, targetID: string): JSONObject {
  const ids = question.criteria.filter(c => c.unitKey === targetID).map(c => c.id);
  const decisions = jsonObject(assessment.decisions), ambiguities = jsonObject(assessment.ambiguities);
  const projected: JSONObject = { ...assessment, decisions: Object.fromEntries(ids.map(id => [id, decisions[id] ?? null])), ambiguities: Object.fromEntries(ids.map(id => [id, ambiguities[id] ?? []])), contradictions: [] };
  projected.outcome = outcome(projected); return projected;
}
function reviewRating(episode: JSONObject, first: JSONObject | undefined, last: JSONObject | undefined, turns: JSONObject[], effort: "easy" | "someEffort" | "veryDifficult" | null, skip: boolean): Grade | null {
  if (skip || !first || episode.disputed || episode.sourceRevealed || first.outcome === "uncertain" || first.sourceConcern) return null;
  const recognition = ["choice", "slider", "ordering", "matching"].includes(stringValue(turns[0]?.inputKind));
  if (recognition) return first.outcome === "correct" ? Rating.Hard : Rating.Again;
  if (Object.values(jsonObject(first.ambiguities)).some(a => jsonArray(a).length)) {
    if (turns.length < 2 || turns.slice(1).some(t => t.kind !== "clarification" || ["choice", "slider", "ordering", "matching"].includes(stringValue(t.inputKind))) || !last || Object.values(jsonObject(last.ambiguities)).some(a => jsonArray(a).length) || last.outcome === "uncertain") return null;
    return last.outcome === "correct" ? Rating.Hard : Rating.Again;
  }
  if (first.outcome === "correct") return effort === "easy" ? Rating.Easy : effort === "veryDifficult" ? Rating.Hard : Rating.Good;
  if (first.outcome === "partial" && last?.outcome === "correct" && turns.slice(1).every(t => t.kind === "clarification" && !["choice", "slider", "ordering", "matching"].includes(stringValue(t.inputKind)))) return Rating.Hard;
  return Rating.Again;
}
export class RecallService {
  constructor(readonly db: Database, readonly ai: AIService, readonly queue: JobQueue) {}
  async prepare(userId: string, subjectID: string, operationID: string, selection: AISelection, regenerateMaterialID: string | null = null) {
    return mutation(this.db, userId, operationID, { action: "prepareRecall", subjectID, selection, regenerateMaterialID }, async tx => {
      const subject = await ownedSubject(tx, userId, subjectID, true);
      if (regenerateMaterialID) requireValue((await tx.select().from(recallMaterials).where(and(eq(recallMaterials.userId, userId), eq(recallMaterials.subjectId, subjectID), eq(recallMaterials.id, regenerateMaterialID))))[0]);
      if (regenerateMaterialID && (await tx.select().from(recallSessions).where(and(eq(recallSessions.userId, userId), eq(recallSessions.subjectId, subjectID), eq(recallSessions.finished, false)))).some(s => jsonArray(s.state.queue).slice(Number(s.state.index ?? 0)).includes(regenerateMaterialID))) throw new DomainError("TARGET_RESERVED", "Finish the open practice session before regenerating this material.", 409);
      const job = requireValue((await tx.insert(jobs).values({ userId, subjectId: subjectID, kind: "prepareRecall", input: { revisionID: subject.revisionId, regenerateMaterialID }, selection, aiConnectionId: selection.connectionID }).returning())[0]);
      await invalidate(tx, userId, "jobs", subjectID, 1); return { jobID: job.id };
    });
  }
  private units(records: LibraryEntity[]): Unit[] {
    const map = new Map(records.map(r => [r.id, r]));
    return records.filter(r => ["fact", "connection"].includes(r.kind) && !r.isRetired).map(entity => {
      const conceptID = stringValue(entity.fields.conceptID) || stringValue(entity.fields.fromConceptID), concept = map.get(conceptID);
      const data: JSONObject = { kind: entity.kind === "fact" ? entity.fields.kind ?? "claim" : "connection", conceptID, conceptName: concept?.fields.name ?? "", statement: entity.fields.statement ?? entity.fields.explanation ?? "", qualifications: entity.fields.qualifications ?? "", reviewNote: entity.fields.reviewNote ?? null,
        evidence: entity.fields.evidence ?? [], relatedConceptIDs: [entity.fields.fromConceptID, entity.fields.toConceptID].filter((s): s is string => typeof s === "string"),
        conceptContext: concept?.fields.explanation ?? "", aliases: concept?.fields.aliases ?? [], classification: entity.fields.kind ?? "" };
      if (entity.kind === "connection") data.conceptName = stringValue(map.get(stringValue(entity.fields.fromConceptID))?.fields.name) + " → " + stringValue(map.get(stringValue(entity.fields.toConceptID))?.fields.name);
      if (entity.kind === "fact") data.reviewNote = [concept?.fields.reviewNote, entity.fields.reviewNote].filter(v => typeof v === "string" && v.trim()).join("\n") || null;
      if (entity.kind === "connection") data.qualifications = (entity.fields.isInferred === true ? "Source-based inference; preserve this qualification. " : "") + stringValue(entity.fields.kind);
      // Evidence refreshes must not erase learned performance for unchanged knowledge.
      const signature = hash({ concept: data.conceptName, aliases: jsonArray(data.aliases).sort(), statement: data.statement, classification: data.classification, qualifications: entity.fields.qualifications ?? "", reviewNote: data.reviewNote ?? null });
      return { key: entity.id, materialID: entity.id, entity, signature, snapshot: data };
    });
  }
  private validateQuestion(q: Question, units: Unit[], focus: string[]) {
    if (new Set(q.criteria.map(c => c.id)).size !== q.criteria.length) throw new DomainError("INVALID_QUESTION", "Question criteria repeat IDs.");
    const keys = new Set(q.criteria.map(c => c.unitKey));
    if (keys.size > 2 || [...keys].some(key => !focus.includes(key))) throw new DomainError("INVALID_QUESTION", "A question covers unrequested material.");
    if (keys.size === 1 && q.kind === "integrated") throw new DomainError("INVALID_QUESTION", "An integrated question must cover multiple targets.");
    for (const c of q.criteria) {
      const unit = requireValue(units.find(u => u.key === c.unitKey));
      const valid = new Set(jsonArray(unit.snapshot.evidence).map(e => evidenceID(unit.key, e)));
      if (c.evidenceIDs.some(id => !valid.has(id))) throw new DomainError("INVALID_QUESTION", "A criterion references another target's evidence.");
    }
    const input = q.input;
    if ("options" in input) {
      const ids = input.options.map(o => o.id); if (new Set(ids).size !== ids.length) throw new DomainError("INVALID_QUESTION", "Answer options repeat IDs.");
      if (input.kind === "choice" && !ids.includes(input.correctOptionID)) throw new DomainError("INVALID_QUESTION", "The answer key is missing.");
      if (input.kind === "ordering" && canonical([...input.correctOrder].sort()) !== canonical([...ids].sort())) throw new DomainError("INVALID_QUESTION", "The ordering key must contain every option once.");
      if (input.kind === "matching" && (input.matches.some(m => !ids.includes(m.leftID) || !ids.includes(m.rightID) || !q.criteria.some(c => c.id === m.criterionID)) || new Set(input.matches.map(m => m.leftID)).size !== input.matches.length || new Set(input.matches.map(m => m.rightID)).size !== input.matches.length)) throw new DomainError("INVALID_QUESTION", "Matching requires a unique verified pairing.");
      if (input.kind === "matching" && (input.matches.some(a => input.matches.some(b => a.leftID === b.rightID)) || canonical([...new Set(input.matches.flatMap(m => [m.leftID, m.rightID]))].sort()) !== canonical([...ids].sort()) || canonical([...new Set(input.matches.map(m => m.criterionID))].sort()) !== canonical(q.criteria.map(c => c.id).sort()))) throw new DomainError("INVALID_QUESTION", "Matching must cover every criterion with distinct left and right items.");
    }
    if (input.kind === "slider" && (input.minimum >= input.maximum || input.expectedValue < input.minimum || input.expectedValue > input.maximum)) throw new DomainError("INVALID_QUESTION", "The numerical answer is outside its control range.");
    if (/\btheor(?:y|ies)\s+(?:[A-D]|[1-9][0-9]?|[IVX]{1,4})\b/i.test(q.prompt)) throw new DomainError("INVALID_QUESTION", "Use meaningful identifiers rather than outline labels.");
  }
  async generate(job: ClaimedJob, signal: AbortSignal) {
    const subject = await ownedSubject(this.db, job.userId, job.subjectId), selection = requireValue(job.selection), records = await snapshot(this.db, job.userId, job.subjectId), units = this.units(records);
    const checkpoint = structuredClone(job.checkpoint), done: JSONObject = {};
    const open = await this.db.select().from(recallSessions).where(and(eq(recallSessions.userId, job.userId), eq(recallSessions.subjectId, job.subjectId), eq(recallSessions.finished, false)));
    const reserved = new Set(open.flatMap(s => jsonArray(s.state.queue).slice(Number(s.state.index ?? 0))));
    const prepared = await this.db.select().from(recallMaterials).where(and(eq(recallMaterials.userId, job.userId), eq(recallMaterials.subjectId, job.subjectId)));
    const history = await this.db.select().from(recallTargets).where(and(eq(recallTargets.userId, job.userId), eq(recallTargets.subjectId, job.subjectId)));
    const exactGroups = new Map<string, Unit[]>(), equivalents = new Map<string, Unit>();
    for (const u of units) {
      const identity = hash({ kind: u.entity.kind, conceptID: u.snapshot.conceptID, endpoints: u.snapshot.relatedConceptIDs, statement: stringValue(u.snapshot.statement).trim(), classification: u.snapshot.classification, qualifications: u.snapshot.qualifications, reviewNote: u.snapshot.reviewNote });
      const group = exactGroups.get(identity) ?? []; group.push(u); exactGroups.set(identity, group);
    }
    for (const group of exactGroups.values()) {
      group.sort((a,b) => Number(history.find(t => t.id === b.key)?.memory?.reps ?? 0) - Number(history.find(t => t.id === a.key)?.memory?.reps ?? 0) || a.key.localeCompare(b.key));
      const canonicalUnit = group[0]!;
      canonicalUnit.snapshot.evidence = [...new Map(group.flatMap(u => jsonArray(u.snapshot.evidence)).map(e => [hash(e), e])).values()];
      for (const duplicate of group.slice(1)) equivalents.set(duplicate.key, canonicalUnit);
    }
    for (const unit of units) {
      const saved = prepared.find(m => m.id === unit.materialID && m.signature === unit.signature);
      if (saved && saved.bank.policyVersion === designVersion && ["ready", "context"].includes(saved.status) && job.input.regenerateMaterialID !== unit.materialID) done[unit.key] = unit.signature;
      if (saved?.signature === unit.signature) unit.snapshot.learningPlan = saved.snapshot.learningPlan ?? null;
    }
    const sourcePassages = units.some(u => u.entity.kind === "connection") ? await this.db.select().from(passages).where(and(eq(passages.userId, job.userId), eq(passages.subjectId, job.subjectId))).orderBy(asc(passages.ordinal)) : [];
    for (const u of units.filter(u => u.entity.kind === "connection")) {
      const evidence = jsonArray(u.snapshot.evidence), anchors = [...evidence];
      let extraBytes = 0;
      for (const raw of anchors) {
        const anchor = jsonObject(raw), source = sourcePassages.filter(p => p.sourceId === anchor.sourceID), index = source.findIndex(p => p.id === anchor.segmentID);
        if (index < 0) continue;
        for (const direction of [-1, 1]) {
          let characters = 0;
          for (let i = index + direction; i >= 0 && i < source.length && characters < 1000; i += direction) {
            const p = source[i]!, reference = { sourceID: p.sourceId, segmentID: p.id, quote: p.text };
            characters += p.text.length;
            const size = Buffer.byteLength(JSON.stringify(reference)); if (extraBytes + size > 6000) break;
            if (!evidence.some(e => jsonObject(e).sourceID === p.sourceId && jsonObject(e).segmentID === p.id)) { evidence.push(reference); extraBytes += size; }
          }
        }
      }
      u.snapshot.evidence = evidence;
    }
    const pending = units.filter(u => done[u.key] !== u.signature && !reserved.has(u.key) && (!job.input.regenerateMaterialID || job.input.regenerateMaterialID === u.key));
    const batches: Unit[][] = [];
    for (const conceptID of [...new Set(pending.map(u => stringValue(u.snapshot.conceptID)))].sort()) {
      const members = pending.filter(u => u.snapshot.conceptID === conceptID).sort((a,b) => a.key.localeCompare(b.key));
      for (let i = 0; i < members.length; i += 6) batches.push(members.slice(i, i + 6));
    }
    let completed = 0;
    const controller = new AbortController();
    signal = AbortSignal.any([signal, controller.signal]);
    const processBatch = async (sourceFocus: Unit[]) => {
      const focus = structuredClone(sourceFocus);
      signal.throwIfAborted();
      const focusKeys = focus.map(u => u.key), contextIDs = new Set(focus.flatMap(u => [stringValue(u.snapshot.conceptID), ...jsonArray(u.snapshot.relatedConceptIDs).map(stringValue)]));
      const neighbours = units.filter(u => u.entity.kind === "connection" && jsonArray(u.snapshot.relatedConceptIDs).some(id => contextIDs.has(stringValue(id)))).flatMap(u => jsonArray(u.snapshot.relatedConceptIDs).map(stringValue)).filter(id => !contextIDs.has(id));
      for (const id of [...new Set(neighbours)].sort().slice(0, 4)) contextIDs.add(id);
      const topics = new Set(records.filter(r => r.kind === "placement" && contextIDs.has(stringValue(r.fields.conceptID))).map(r => stringValue(r.fields.topicID)));
      for (const id of [...new Set(records.filter(r => r.kind === "placement" && topics.has(stringValue(r.fields.topicID))).map(r => stringValue(r.fields.conceptID)))].sort().filter(id => !contextIDs.has(id)).slice(0, 4)) contextIDs.add(id);
      let bytes = Buffer.byteLength(JSON.stringify(focus));
      const bundle = [...focus];
      for (const u of units.filter(u => !focusKeys.includes(u.key) && !reserved.has(u.key) && contextIDs.has(stringValue(u.snapshot.conceptID))).sort((a,b) => a.key.localeCompare(b.key))) {
        const size = Buffer.byteLength(JSON.stringify(u.snapshot)); if (bytes + size > 55_000) continue; bytes += size; bundle.push(structuredClone(u));
      }
      const contexts = records.filter(r => r.kind === "concept" && !r.isRetired && contextIDs.has(r.id)).map(r => ({ id: r.id, name: r.fields.name ?? "", aliases: r.fields.aliases ?? [], definition: r.fields.explanation ?? "", statements: units.filter(u => u.snapshot.conceptID === r.id).map(u => u.snapshot.statement) }));
      const plans: JSONObject = {}, issues: JSONObject = {};
      for (const u of focus) {
        const equivalent = equivalents.get(u.key);
        if (equivalent) plans[u.key] = { version: designVersion, disposition: "duplicate", reason: "Identical saved knowledge shares one practice target.", canonicalMaterialID: equivalent.key, canonicalSignature: equivalent.signature, equivalentKey: equivalent.key };
      }
      const eligible = focus.filter(u => !equivalents.has(u.key) && !u.snapshot.reviewNote && jsonArray(u.snapshot.evidence).length);
      for (const u of focus.filter(u => !eligible.includes(u) && !equivalents.has(u.key))) { plans[u.key] = { disposition: "sourceIssue", reason: u.snapshot.reviewNote ?? "This target has no saved source evidence." }; issues[u.key] = jsonObject(plans[u.key]).reason!; }
      const toPlan = eligible.filter(u => jsonObject(u.snapshot.learningPlan ?? {}).version !== designVersion || !jsonArray(jsonObject(u.snapshot.learningPlan ?? {}).evidenceQuotes).every(q => jsonArray(u.snapshot.evidence).some(e => stringValue(jsonObject(e).quote).includes(stringValue(q)))) || job.input.regenerateMaterialID === u.key);
      for (const u of eligible.filter(u => !toPlan.includes(u))) plans[u.key] = u.snapshot.learningPlan!;
      if (toPlan.length) {
        const result = await structured(this.ai, job.userId, selection, "recall_plan", policies.recall_learningPlanInstructions,
          { focusKeys: toPlan.map(u => u.key), units: asJSON(bundle.map(u => unitInput(u))) }, z.strictObject({ plans: keyed(toPlan.map(u => u.key), learningPlanSchema) }), signal);
        for (const u of toPlan) {
          const proposal = result.plans[u.key]!, canonical = bundle.find(c => c.key === proposal.equivalentKey);
          const grounded = proposal.evidenceQuotes.every(q => bounded(q, 1000) && jsonArray(u.snapshot.evidence).some(e => stringValue(jsonObject(e).quote).includes(q)));
          const duplicateValid = proposal.disposition !== "duplicate" ? proposal.equivalentKey === null : u.entity.kind === "connection" && canonical?.entity.kind === "fact" && !canonical.snapshot.reviewNote && jsonArray(canonical.snapshot.evidence).length > 0 && (result.plans[canonical.key]?.disposition ?? jsonObject(canonical.snapshot.learningPlan ?? {}).disposition) === "practice";
          plans[u.key] = grounded && duplicateValid && bounded(proposal.reason, 1000) && [...proposal.essentialMeanings, ...proposal.contextualMeanings, ...proposal.optionalPrecision].every(m => bounded(m, 600)) && (proposal.disposition !== "practice" || bounded(proposal.objective, 400) && proposal.essentialMeanings.length > 0)
            ? { ...asJSON(proposal) as JSONObject, version: designVersion, canonicalMaterialID: canonical?.materialID ?? null, canonicalSignature: canonical?.signature ?? null }
            : { version: designVersion, disposition: "practice", objective: "Retrieve the essential meaning of this saved claim.", essentialMeanings: [u.snapshot.statement!], contextualMeanings: [], optionalPrecision: [], reason: "Preserve this target for independent question verification.", evidenceQuotes: jsonArray(u.snapshot.evidence).slice(0,1).map(e => jsonObject(e).quote!), equivalentKey: null };
        }
        const nonPractice = toPlan.filter(u => jsonObject(plans[u.key]).disposition !== "practice").map(u => u.key);
        if (nonPractice.length) {
          const review = await structured(this.ai, job.userId, selection, "recall_plan_review", policies.recall_learningPlanReviewInstructions,
            { units: asJSON(bundle.map(u => unitInput(u))), proposals: Object.fromEntries(nonPractice.map(k => [k, plans[k]!])) }, z.strictObject({ reviews: keyed(nonPractice, z.strictObject({ approved: z.boolean(), reason: z.string() })) }), signal);
          for (const key of nonPractice) if (!review.reviews[key]?.approved) plans[key] = { ...jsonObject(plans[key]), disposition: "practice", objective: "Retrieve the essential meaning of this saved claim.", essentialMeanings: [focus.find(u => u.key === key)!.snapshot.statement!], equivalentKey: null, canonicalMaterialID: null, canonicalSignature: null };
        }
      }
      for (const u of bundle) if (plans[u.key]) u.snapshot.learningPlan = plans[u.key]!;
      // Save eligibility before spending requests on drafts; do not mark uncovered practice as failed yet.
      await this.install(job, subject.revisionId, focus, plans, [], issues, true);
      const practice = eligible.filter(u => jsonObject(plans[u.key]).disposition === "practice"), blocked = new Set<string>();
      const currentBanks = await this.db.select().from(recallMaterials).where(and(eq(recallMaterials.userId, job.userId), eq(recallMaterials.subjectId, job.subjectId)));
      const accepted: Question[] = [...new Map(currentBanks.filter(m => !history.some(t => t.id === m.id && t.excluded) && bundle.some(u => u.key === m.id && u.signature === m.signature) && job.input.regenerateMaterialID !== m.id).flatMap(m => jsonArray(m.bank.questions).map(q => jsonObject(q) as unknown as Question)).filter(q => q.verified && q.designVersion === designVersion && q.criteria.every(c => bundle.some(u => u.key === c.unitKey && c.evidenceIDs.every(id => jsonArray(u.snapshot.evidence).some(e => evidenceID(u.key,e) === id))))).map(q => [q.id, q])).values()];
      let rejected: Question[] = [];
      const diagnostics: JSONObject[] = [];
      const accept = async (proposed: Question, keys: string[], enrichment: boolean) => {
        const q = { ...proposed, expectedAnswer: proposed.expectedAnswer.trim() || proposed.criteria.map(c => c.point).join(" "), id: randomUUID(), verified: false, designVersion, preparationModel: selection.model };
        try {
          this.validateQuestion(q, bundle, keys); validateDesign(q, bundle, keys, enrichment);
          await this.verifyQuestion(job, bundle, q, signal, plans);
          q.targetSignatures = Object.fromEntries([...new Set(q.criteria.map(c => c.unitKey))].map(key => [key, bundle.find(u => u.key === key)!.signature]));
          diagnostics.push({ stage: "verified", questionID: q.id, prompt: q.prompt, format: q.input.kind });
          const cited = new Set([...q.criteria.flatMap(c => c.evidenceIDs), ...q.precisionNotes.flatMap(n => n.evidenceIDs)]);
          q.evidenceCatalog = Object.fromEntries(bundle.flatMap(u => jsonArray(u.snapshot.evidence).filter(e => cited.has(evidenceID(u.key, e))).map(e => [evidenceID(u.key, e), e])));
          accepted.push(q); for (const key of new Set(q.criteria.map(c => c.unitKey))) delete issues[key];
          await this.install(job, subject.revisionId, bundle.filter(u => focusKeys.includes(u.key) || accepted.some(q => q.criteria.every(c => c.unitKey === u.key))), plans, accepted, issues, false, diagnostics.slice(-12));
        } catch (error) {
          if (!(error instanceof DomainError) || !["INVALID_QUESTION", "INVALID_AI_RESPONSE"].includes(error.code)) throw error;
          for (const c of q.criteria) issues[c.unitKey] = error.message;
          diagnostics.push({ stage: "rejected", questionID: q.id, prompt: q.prompt, format: q.input.kind, issue: error.message.slice(0, 4000), review: asJSON(q.verification ?? {}) });
          rejected.push(q);
        }
      };
      for (let attempt = 0; attempt < 3; attempt++) {
        const missing = practice.filter(u => !blocked.has(u.key) && !accepted.some(q => q.criteria.every(c => c.unitKey === u.key)));
        if (!missing.length) break;
        const keys = missing.map(u => u.key), prior = rejected; rejected = [];
        const patches = prior.filter(q => q.criteria.length > 0 && new Set(q.criteria.map(c => c.unitKey)).size === 1 && keys.includes(q.criteria[0]!.unitKey) && typeof q.verification?.promptRepair === "string");
        for (const patch of patches) await accept({ ...patch, prompt: patch.verification!.promptRepair as string }, [patch.criteria[0]!.unitKey], false);
        const draftKeys = keys.filter(k => !patches.some(q => q.criteria[0]!.unitKey === k));
        if (!draftKeys.length) continue;
        try {
          const generated = await structured(this.ai, job.userId, selection, "recall_design", policies.design_designInstructions,
            { focusKeys: draftKeys, units: asJSON(bundle.map(u => unitInput(u, plans))), concepts: asJSON(contexts), repairIssues: issues,
              previousRejectedQuestions: asJSON(prior.slice(-6).map(q => repairExample(q, bundle)).filter((_, i, all) => Buffer.byteLength(JSON.stringify(all.slice(0, i + 1))) <= 12_000)), includeIntegratedQuestions: false, mode: "coverage", existingQuestions: [], enrichmentKeys: [], requestedFormat: null }, designBankSchema(draftKeys.length, draftKeys), signal);
          for (const b of generated.blocked) if (draftKeys.includes(b.key) && bounded(b.reason, 2000)) { blocked.add(b.key); plans[b.key] = { ...jsonObject(plans[b.key]), disposition: "sourceIssue", reason: b.reason }; issues[b.key] = b.reason; }
          for (const q of generated.questions) await accept(q as Question, draftKeys, false);
        } catch (error) {
          if (!(error instanceof DomainError) || error.code !== "INVALID_AI_RESPONSE") throw error;
          for (const k of draftKeys) issues[k] = error.message;
        }
      }
      for (const u of bundle.filter(u => !focusKeys.includes(u.key))) {
        const saved = currentBanks.find(m => m.id === u.key && m.signature === u.signature);
        if (saved) u.snapshot.learningPlan = saved.snapshot.learningPlan ?? null;
      }
      const enrichment = enrichmentSelection(bundle, focusKeys, accepted);
      if (enrichment.keys.length) {
        try {
          const enriched = await structured(this.ai, job.userId, selection, "recall_enrichment", policies.design_designInstructions,
            { focusKeys: [], units: asJSON(bundle.map(u => unitInput(u, plans))), concepts: asJSON(contexts), repairIssues: {}, previousRejectedQuestions: [], includeIntegratedQuestions: true,
              mode: "enrichment", existingQuestions: asJSON(accepted.map(q => ({ prompt: q.prompt, expectedAnswer: q.expectedAnswer, requiredMeanings: q.criteria.map(c => c.requiredMeaning), inputKind: q.input.kind }))), enrichmentKeys: enrichment.keys, requestedFormat: enrichment.format }, designBankSchema(1, enrichment.keys, enrichment.format), signal, true, 1);
          for (const q of enriched.questions) if (!accepted.some(a => a.prompt === q.prompt && a.input.kind === q.input.kind)) await accept(q as Question, enrichment.keys, true);
        } catch (error) {
          if (signal.aborted || !(error instanceof DomainError) || ["AI_UNAUTHORIZED", "AI_DISCONNECTED", "AI_LIMIT", "MATERIAL_CHANGED"].includes(error.code)) throw error;
          // Optional enrichment cannot discard already prepared coverage.
        }
      }
      for (const u of practice) {
        if (accepted.some(q => q.criteria.every(c => c.unitKey === u.key))) delete issues[u.key];
        else issues[u.key] ??= "No verified focused question was produced after bounded repairs. Retry preparation.";
      }
      await this.install(job, subject.revisionId, bundle.filter(u => focusKeys.includes(u.key) || accepted.some(q => q.criteria.every(c => c.unitKey === u.key))), plans, accepted, issues, false, diagnostics.slice(-12));
      completed += focus.length; checkpoint.materials = done; await this.queue.checkpoint(job, checkpoint, { stage: "preparingRecall", completed, total: pending.length });
    };
    const concurrency = Math.min(16, batches.length);
    let cursor = 0, failure: unknown;
    const workers = Array.from({ length: concurrency }, async () => {
      try {
        for (;;) { signal.throwIfAborted(); const batch = batches[cursor++]; if (!batch) return; await processBatch(batch); }
      } catch (error) { failure ??= error; controller.abort(); throw error; }
    });
    await Promise.allSettled(workers);
    if (failure) throw failure;
    await this.queue.complete(job, async () => {});
  }
  private async verifyQuestion(job: ClaimedJob, focus: Unit[], question: Question, signal: AbortSignal, plans: JSONObject = {}) {
    const selection = requireValue(job.selection);
    const unitKeys = [...new Set(question.criteria.map(c => c.unitKey))];
    const verdict = await structured(this.ai, job.userId, selection, "recall_verification", policies.design_designVerificationInstructions,
      asJSON(verificationInput(question, focus, plans)) as JSONObject,
      z.strictObject({ reviews: keyed([question.id], verificationSchema(question, unitKeys)) }), signal);
    const review = verdict.reviews[question.id]!;
    question.verification = { ...review, promptRepair: null };
    const quality = review.quality;
    const scopeMismatch = review.scopeCheck.validUnderPrompt && !review.scopeCheck.coveredByRubric && review.scopeCheck.sourceSupported && review.scopeCheck.supportingQuotes.length > 0 && review.scopeCheck.supportingQuotes.every(q => bounded(q, 1000) && focus.some(u => jsonArray(u.snapshot.evidence).some(e => stringValue(jsonObject(e).quote).includes(q))));
    const substantiveIssues = review.issues.filter(i => i.basis !== "scope" || scopeMismatch);
    const repairable = substantiveIssues.every(i => ["scope", "presentation"].includes(i.basis)) && (scopeMismatch || substantiveIssues.length > 0 || review.optionalCriteriaRequested);
    if (repairable && review.promptRepair && bounded(review.promptRepair, 1200) && review.promptRepair !== question.prompt) {
      question.verification = { ...review, promptRepair: review.promptRepair };
      if (review.optionalCriteriaRequested && question.input.kind === "text") {
        question.criteria = question.criteria.filter(c => review.criterionEssentials[c.id]?.essential);
        question.expectedAnswer = question.criteria.map(c => c.point).join(" ");
      }
    }
    if (!bounded(quality.objective, 400) || unitKeys.length > 1 && (!bounded(quality.comparisonAxis, 400) || !bounded(quality.integrationBenefit, 600))) throw new DomainError("INVALID_QUESTION", "Integration needs one supported comparison axis and a useful retrieval benefit.");
    if (substantiveIssues.length || scopeMismatch || !quality.usefulRetrieval || !quality.cueSafe || !quality.manageable || !quality.meaningfulCues || (unitKeys.length === 1 ? !quality.singleTargetCoherent : !quality.focused || !["contrast", "relationship"].includes(quality.combination))) throw new DomainError("INVALID_QUESTION", substantiveIssues.map(i => `${i.gate}: ${i.problem} Example: ${i.counterexample} Repair: ${i.repair}`).join("; ") || quality.reason);
    if (question.criteria.some(c => !review.criterionSupport[c.id]?.supported) || unitKeys.some(key => review.coverage[key]?.status !== "complete" || review.coverage[key]!.missingParts.length)) throw new DomainError("INVALID_QUESTION", "The rubric does not fully cover the supported target meaning.");
    const essentialCount = question.criteria.filter(c => review.criterionEssentials[c.id]?.essential).length;
    if (essentialCount < question.criteria.length && (review.optionalCriteriaRequested || question.input.kind !== "text")) throw new DomainError("INVALID_QUESTION", "Align the visible task and keyed controls with essential criteria before verification.");
    if (question.input.kind === "matching" && (new Set(Object.values(review.matchingDimensions)).size !== 1 || question.input.matches.some(pair => canonical(review.matchingAnswers[pair.leftID]) !== canonical([pair.rightID])))) throw new DomainError("INVALID_QUESTION", "Matching needs one unique answer per item on the same semantic dimension.");
    const visible = [question.prompt, ...("options" in question.input ? question.input.options.map(o => o.text) : [])].join("\n");
    const disclosures = review.disclosures.filter(d => !unitKeys.includes(stringValue(jsonObject(plans[d.materialID] ?? focus.find(u => u.key === d.materialID)?.snapshot.learningPlan ?? {}).canonicalMaterialID))).map(disclosure => {
      const unit = focus.find(u => u.materialID === disclosure.materialID);
      if (!unit || unitKeys.includes(disclosure.materialID) || !disclosure.necessary || disclosure.visibleQuotes.some(q => !visible.includes(q)) || disclosure.evidenceQuotes.some(q => !jsonArray(unit.snapshot.evidence).some(e => stringValue(jsonObject(e).quote).includes(q)))) throw new DomainError("INVALID_QUESTION", "Disclosures require necessary visible context and exact supporting evidence for an unassessed target.");
      return { ...disclosure, signature: unit.signature };
    });
    for (const c of question.criteria.filter(c => review.criterionEssentials[c.id]?.essential)) {
      if (question.input.kind === "text" && review.independentParts[c.id]!.length !== 1) throw new DomainError("INVALID_QUESTION", `Split independently requested meanings in criterion ${c.id} into separate criteria under the same target.`);
      if (!bounded(review.requiredMeanings[c.id]!, 1000) || !bounded(review.contextualAnswers[c.id]!, 600) || review.acceptedAnswers[c.id]!.some(a => !bounded(a, 400))) throw new DomainError("INVALID_QUESTION", "Use concise reviewed contextual meanings and valid natural answers.");
      if (review.promptGivens[c.id]!.some(g => !visible.includes(g) && g.trim().toLowerCase() === review.requiredMeanings[c.id]!.trim().toLowerCase())) throw new DomainError("INVALID_QUESTION", "New requested meaning cannot be treated as unseen given context.");
    }
    question.criteria = question.criteria.filter(c => review.criterionEssentials[c.id]?.essential).map(c => ({ ...c, requiredMeaning: review.requiredMeanings[c.id]!, requestedPart: review.independentParts[c.id]![0]!, essentialReason: review.criterionEssentials[c.id]!.reason,
      promptGivens: review.promptGivens[c.id]!.filter(g => visible.includes(g)), acceptedExamples: [...new Set([...review.acceptedAnswers[c.id]!, review.contextualAnswers[c.id]!])].slice(0,3) }));
    question.practiceValue = review.practiceValue;
    if (!question.criteria.length || unitKeys.some(key => !question.criteria.some(c => c.unitKey === key))) throw new DomainError("INVALID_QUESTION", "Each target requires an essential response criterion.");
    question.precisionNotes = question.precisionNotes.filter(n => !review.omitPrecisionNoteIDs.includes(n.id)); question.verified = true; question.verification = { ...review, disclosures };
    return question;
  }
  private async install(job: ClaimedJob, revisionID: string, units: Unit[], plans: JSONObject, questions: Question[], issues: JSONObject, planningOnly = false, diagnostics: JSONObject[] = []) {
    await this.queue.fenced(job, async tx => {
      const subject = await ownedSubject(tx, job.userId, job.subjectId, true); if (subject.revisionId !== revisionID) throw new DomainError("MATERIAL_CHANGED", "The subject changed during preparation. Retry to use the latest saved material.", 409);
      const active = await tx.select().from(recallSessions).where(and(eq(recallSessions.userId, job.userId), eq(recallSessions.subjectId, job.subjectId), eq(recallSessions.finished, false)));
      const reserved = new Set(active.flatMap(s => jsonArray(s.state.queue).slice(Number(s.state.index ?? 0))));
      for (const unit of units) {
        if (reserved.has(unit.materialID)) continue;
        const existing = (await tx.select().from(recallMaterials).where(and(eq(recallMaterials.userId, job.userId), eq(recallMaterials.subjectId, job.subjectId), eq(recallMaterials.id, unit.materialID))))[0];
        const saved = existing?.signature === unit.signature && job.input.regenerateMaterialID !== unit.materialID ? jsonArray(existing.bank.questions).map(q => jsonObject(q) as unknown as Question).filter(q => q.designVersion === designVersion && q.criteria.every(c => c.unitKey !== unit.key || c.evidenceIDs.every(id => jsonArray(unit.snapshot.evidence).some(e => evidenceID(c.unitKey, e) === id)))) : [];
        const combined = [...new Map([...saved, ...questions.filter(q => q.criteria.some(c => c.unitKey === unit.key))].map(q => [q.id, q])).values()];
        const plan = plans[unit.key] ?? unit.snapshot.learningPlan ?? { disposition: "practice" };
        const disposition = stringValue(jsonObject(plan).disposition), sourceIssue = !!unit.snapshot.reviewNote || jsonArray(unit.snapshot.evidence).length === 0;
        const status = sourceIssue ? "sourceIssue" : disposition !== "practice" ? disposition : combined.some(q => new Set(q.criteria.map(c => c.unitKey)).size === 1 && q.criteria[0]?.unitKey === unit.key) ? "ready" : planningOnly ? "pending" : "failed";
        const bank: JSONObject = { questions: asJSON(combined), issue: issues[unit.key] ?? null, policyVersion: designVersion, diagnostics };
        await tx.insert(recallMaterials).values({ id: unit.materialID, userId: job.userId, subjectId: job.subjectId, entityId: unit.entity.id, signature: unit.signature, status, snapshot: { ...unit.snapshot, learningPlan: plan }, bank, revisionId: revisionID })
          .onConflictDoUpdate({ target: [recallMaterials.userId, recallMaterials.subjectId, recallMaterials.id], set: { signature: unit.signature, status, snapshot: { ...unit.snapshot, learningPlan: plan }, bank, revisionId: revisionID, updatedAt: new Date() } });
        const old = (await tx.select().from(recallTargets).where(and(eq(recallTargets.userId, job.userId), eq(recallTargets.subjectId, job.subjectId), eq(recallTargets.id, unit.materialID))))[0];
        await tx.insert(recallTargets).values({ id: unit.materialID, userId: job.userId, subjectId: job.subjectId, materialId: unit.materialID, signature: unit.signature, data: bank, retired: false })
          .onConflictDoUpdate({ target: [recallTargets.userId, recallTargets.subjectId, recallTargets.id], set: { signature: unit.signature, data: bank, retired: false, ...(!planningOnly && status === "ready" && questions.some(q => q.criteria.some(c => c.unitKey === unit.key)) ? { excluded: false } : {}), ...(old && old.signature !== unit.signature ? { memory: null, dueAt: null } : {}), version: sql`${recallTargets.version}+1` } });
      }
      await invalidate(tx, job.userId, "recall", job.subjectId, subject.version);
    });
  }
  private async scopeConcepts(tx: Database | Transaction, userId: string, subjectID: string, topicID: string | null, loadedRecords?: LibraryEntity[]) {
    if (!topicID) return null;
    const records = loadedRecords ?? await snapshot(tx, userId, subjectID), included = new Set([topicID]);
    if (!records.some(r => r.id === topicID && r.kind === "topic" && !r.isRetired)) throw new DomainError("NOT_FOUND", "This topic is unavailable.", 404);
    let changed = true;
    while (changed) { changed = false; for (const r of records) if (r.kind === "topic" && !r.isRetired && typeof r.fields.parentID === "string" && included.has(r.fields.parentID) && !included.has(r.id)) { included.add(r.id); changed = true; } }
    return new Set(records.filter(r => r.kind === "placement" && !r.isRetired && typeof r.fields.topicID === "string" && included.has(r.fields.topicID)).map(r => stringValue(r.fields.conceptID)));
  }
  async dashboard(userId: string, subjectID: string, topicID: string | null = null, read: Database | Transaction = this.db, subjectRecords?: LibraryEntity[], confirmedSubject?: Awaited<ReturnType<typeof ownedSubject>>): Promise<RecallDashboard> {
    const subject = confirmedSubject ?? await ownedSubject(read, userId, subjectID), materials = await read.select({ id: recallMaterials.id, entityId: recallMaterials.entityId, revisionId: recallMaterials.revisionId, status: recallMaterials.status,
      snapshot: sql<JSONObject>`jsonb_build_object('conceptID', ${recallMaterials.snapshot}->'conceptID', 'relatedConceptIDs', ${recallMaterials.snapshot}->'relatedConceptIDs',
        'learningPlan', jsonb_build_object('canonicalMaterialID', ${recallMaterials.snapshot}->'learningPlan'->'canonicalMaterialID', 'equivalentKey', ${recallMaterials.snapshot}->'learningPlan'->'equivalentKey'))`,
      bank: sql<JSONObject>`jsonb_build_object('policyVersion', ${recallMaterials.bank}->'policyVersion')` }).from(recallMaterials).where(and(eq(recallMaterials.userId, userId), eq(recallMaterials.subjectId, subjectID)));
    const targets = await read.select({ id: recallTargets.id, materialId: recallTargets.materialId, excluded: recallTargets.excluded, memory: recallTargets.memory,
      dueAt: recallTargets.dueAt, exposedAt: recallTargets.exposedAt }).from(recallTargets).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, subjectID), eq(recallTargets.retired, false)));
    const records = subjectRecords ?? (await read.select({ record: sql<LibraryEntity>`${entities.record} || jsonb_build_object('fields', jsonb_build_object(
      'name', ${entities.record}->'fields'->'name', 'parentID', ${entities.record}->'fields'->'parentID',
      'conceptID', ${entities.record}->'fields'->'conceptID', 'topicID', ${entities.record}->'fields'->'topicID'))` }).from(entities)
      .where(and(eq(entities.userId, userId), eq(entities.subjectId, subjectID), inArray(entities.kind, ["concept", "topic", "placement"])))).map(r => r.record);
    const concepts = records.filter(r => r.kind === "concept" && !r.isRetired);
    const conceptIDs = await this.scopeConcepts(read, userId, subjectID, topicID, records), scoped = materials.filter(m => !conceptIDs || conceptIDs.has(stringValue(m.snapshot.conceptID)) || jsonArray(m.snapshot.relatedConceptIDs).some(id => typeof id === "string" && conceptIDs.has(id)));
    const current = new Set(scoped.filter(m => m.status === "ready" && m.revisionId === subject.revisionId).map(m => m.id));
    const now = new Date(), usable = targets.filter(t => current.has(t.materialId) && !t.excluded);
    const due = usable.filter(t => (!t.dueAt || t.dueAt <= now) && (!t.exposedAt || t.exposedAt.getTime() + 600_000 <= now.getTime()));
    const scores = await this.scores(userId, subjectID, usable, read);
    type Proficiency = RecallProficiency;
    const empty = (): Proficiency => ({ units: 0, assessedTargets: 0, targetSlots: 0, readinessSum: 0 });
    const sum = (values: Proficiency[]) => values.reduce((result, value) => ({ units: result.units + value.units, assessedTargets: result.assessedTargets + value.assessedTargets, targetSlots: result.targetSlots + value.targetSlots, readinessSum: result.readinessSum + value.readinessSum }), empty());
    const materialScores = new Map<string, Proficiency>();
    const targetByMaterial = new Map<string, typeof usable[number]>();
    for (const target of usable) if (!targetByMaterial.has(target.materialId)) targetByMaterial.set(target.materialId, target);
    for (const material of materials.filter(m => m.revisionId === subject.revisionId && !["retired", "context", "duplicate"].includes(m.status))) {
      const target = targetByMaterial.get(material.id), score = target ? scores[target.id] : null;
      materialScores.set(material.id, { units: 1, assessedTargets: typeof score === "number" ? 1 : 0, targetSlots: 1, readinessSum: typeof score === "number" ? score : 0 });
    }
    const proficiencyByConcept: Record<string, Proficiency> = {};
    const materialsByConcept = new Map<string, typeof materials>();
    for (const material of materials) {
      if (material.revisionId !== subject.revisionId) continue;
      const ids = new Set([material.snapshot.conceptID, ...jsonArray(material.snapshot.relatedConceptIDs)].filter((id): id is string => typeof id === "string"));
      for (const id of ids) {
        const values = materialsByConcept.get(id);
        if (values) values.push(material); else materialsByConcept.set(id, [material]);
      }
    }
    for (const concept of concepts) {
      const relevant = materialsByConcept.get(concept.id) ?? [];
      const unitIDs = new Set(relevant.flatMap(m => m.status === "duplicate" ? [stringValue(jsonObject(m.snapshot.learningPlan).canonicalMaterialID) || stringValue(jsonObject(m.snapshot.learningPlan).equivalentKey)] : [m.id]));
      let value = sum([...unitIDs].flatMap(id => materialScores.has(id) ? [materialScores.get(id)!] : []));
      if (!value.units && !relevant.some(m => ["context", "duplicate"].includes(m.status))) value = { units: 1, assessedTargets: 0, targetSlots: 1, readinessSum: 0 };
      proficiencyByConcept[concept.id] = value;
    }
    const proficiencyByTopic: Record<string, Proficiency> = {};
    for (const topic of records.filter(r => r.kind === "topic" && !r.isRetired)) {
      const ids = new Set([topic.id]); let changed = true;
      while (changed) { changed = false; for (const child of records) if (child.kind === "topic" && !child.isRetired && typeof child.fields.parentID === "string" && ids.has(child.fields.parentID) && !ids.has(child.id)) { ids.add(child.id); changed = true; } }
      const members = new Set(records.filter(r => r.kind === "placement" && !r.isRetired && typeof r.fields.topicID === "string" && ids.has(r.fields.topicID)).map(r => stringValue(r.fields.conceptID)));
      proficiencyByTopic[topic.id] = sum([...members].flatMap(id => proficiencyByConcept[id] ? [proficiencyByConcept[id]!] : []));
    }
    const nextDue = usable.map(t => t.dueAt ? new Date(Math.max(t.dueAt.getTime(), t.exposedAt ? t.exposedAt.getTime() + 600_000 : 0)) : null).filter((date): date is Date => date !== null && date > now).sort((a, b) => a.getTime() - b.getTime())[0];
    const overview = { total: scoped.filter(m => !["context", "duplicate", "retired"].includes(m.status)).length, prepared: usable.length, assessed: usable.filter(t => t.memory).length,
      due: due.filter(t => t.dueAt !== null).length, new: due.filter(t => !t.memory).length, issues: targets.filter(t => current.has(t.materialId) && t.excluded).length,
      materialUpgrade: scoped.filter(m => m.bank.policyVersion !== designVersion && !["retired", "context", "duplicate"].includes(m.status)).length,
      materialPending: scoped.filter(m => ["pending", "stale", "failed"].includes(m.status)).length, materialBlocked: scoped.filter(m => ["blocked", "sourceIssue"].includes(m.status)).length,
      contextMaterials: scoped.filter(m => m.status === "context").length, duplicateMaterials: scoped.filter(m => m.status === "duplicate").length, nextDueAt: nextDue?.toISOString() ?? null,
      scopeName: topicID ? (records.find(r => r.id === topicID)?.fields.name ?? "Topic") as string : subject.name };
    return { subjectID, due: due.length, total: usable.length, unassessed: usable.filter(t => !t.memory).length, proficiency: scores, proficiencyByConcept, proficiencyByTopic, overview };
  }
  async materials(userId: string, subjectID: string, cursor?: string, limit = 50, includeQuestions = true): Promise<Page<RecallMaterialDisplay>> {
    const subject = await ownedSubject(this.db, userId, subjectID);
    const rows = await this.db.select({ material: { id: recallMaterials.id, entityId: recallMaterials.entityId, status: recallMaterials.status, signature: recallMaterials.signature,
      snapshot: recallMaterials.snapshot, revisionId: recallMaterials.revisionId,
      bank: includeQuestions ? recallMaterials.bank : sql<JSONObject>`jsonb_build_object('issue', ${recallMaterials.bank}->'issue')` },
      target: { id: recallTargets.id, version: recallTargets.version, excluded: recallTargets.excluded, dueAt: recallTargets.dueAt, memory: recallTargets.memory, exposedAt: recallTargets.exposedAt,
        issue: sql<JSONValue>`${recallTargets.data}->'reportedIssue'` } }).from(recallMaterials).leftJoin(recallTargets, and(eq(recallTargets.userId, recallMaterials.userId), eq(recallTargets.subjectId, recallMaterials.subjectId), eq(recallTargets.materialId, recallMaterials.id)))
      .where(and(eq(recallMaterials.userId, userId), eq(recallMaterials.subjectId, subjectID), cursor ? gt(recallMaterials.id, cursor) : undefined)).orderBy(asc(recallMaterials.id)).limit(limit + 1);
    return { items: rows.slice(0, limit).map(({ material: m, target }) => {
      const available = !target?.exposedAt || target.exposedAt.getTime() + 600_000 <= Date.now();
      return { id: m.id, entityID: m.entityId, status: m.status, signature: m.signature, snapshot: m.snapshot, current: m.revisionId === subject.revisionId && !["stale", "pending", "retired"].includes(m.status), bank: m.bank,
        target: target ? { id: target.id, version: target.version, excluded: target.excluded, dueAt: target.dueAt?.toISOString() ?? null, memory: target.memory, assessed: !!target.memory, isNew: !target.memory && available, due: !!target.dueAt && target.dueAt <= new Date() && available, issue: target.issue ?? null } : null };
    }), nextCursor: rows.length > limit ? rows[limit - 1]!.material.id : null };
  }
  private async scores(userId: string, subjectID: string, targets: Pick<Target, "id" | "memory">[], read: Database | Transaction = this.db): Promise<RecallDashboard["proficiency"]> {
    if (!targets.length) return {};
    const events = await read.select({ id: learningEvents.id, targetId: learningEvents.targetId, kind: learningEvents.kind, relatedEventId: learningEvents.relatedEventId,
      payload: sql<JSONObject>`jsonb_build_object('rating', ${learningEvents.payload}->'rating', 'recognition', ${learningEvents.payload}->'recognition',
        'afterMemory', ${learningEvents.payload}->'afterMemory', 'supportedCorrect', ${learningEvents.payload}->'supportedCorrect')` }).from(learningEvents)
      .where(and(eq(learningEvents.userId, userId), eq(learningEvents.subjectId, subjectID))).orderBy(desc(learningEvents.createdAt));
    const undone = new Set(events.filter(e => e.kind === "undo").map(e => e.relatedEventId));
    const latest = new Map<string, typeof events[number]>(), scheduledEvents = new Map<string, typeof events[number]>();
    for (const event of events) {
      if (event.kind !== "review" || undone.has(event.id)) continue;
      if (!latest.has(event.targetId)) latest.set(event.targetId, event);
      if (typeof event.payload.rating === "number" && !scheduledEvents.has(event.targetId)) scheduledEvents.set(event.targetId, event);
    }
    const result: RecallDashboard["proficiency"] = {};
    for (const target of targets) {
      const last = latest.get(target.id);
      const scheduled = scheduledEvents.get(target.id);
      if (!target.memory || !scheduled || canonical(scheduled.payload.afterMemory) !== canonical(target.memory)) { result[target.id] = null; continue; }
      const rating = scheduled.payload.rating, recognized = scheduled.payload.recognition === true;
      let readiness = Number(scheduler.retrievability(card(target.memory, new Date()), new Date()));
      if (!Number.isFinite(readiness)) readiness = 0;
      result[target.id] = typeof rating === "number" && rating >= Rating.Hard ? readiness * (recognized ? 0.5 : 1) : last?.payload.supportedCorrect === true ? readiness * 0.5 : 0;
    }
    return result;
  }
  async newSession(userId: string, subjectID: string, operationID: string, selection: AISelection, topicID: string | null = null) {
    return mutation(this.db, userId, operationID, { action: "newRecallSession", subjectID, selection, topicID }, async tx => {
      const subject = await ownedSubject(tx, userId, subjectID, true);
      let conceptIDs: Set<string> | null = null;
      if (topicID) {
        const records = await snapshot(tx, userId, subjectID), included = new Set([topicID]); let changed = true;
        if (!records.some(r => r.id === topicID && r.kind === "topic" && !r.isRetired)) throw new DomainError("NOT_FOUND", "This topic is unavailable.", 404);
        while (changed) { changed = false; for (const r of records) if (r.kind === "topic" && typeof r.fields.parentID === "string" && included.has(r.fields.parentID) && !included.has(r.id)) { included.add(r.id); changed = true; } }
        conceptIDs = new Set(records.filter(r => r.kind === "placement" && typeof r.fields.topicID === "string" && included.has(r.fields.topicID)).map(r => stringValue(r.fields.conceptID)));
      }
      const candidates = await tx.select({ target: recallTargets, material: recallMaterials }).from(recallTargets).innerJoin(recallMaterials, and(eq(recallTargets.userId, recallMaterials.userId), eq(recallTargets.subjectId, recallMaterials.subjectId), eq(recallTargets.materialId, recallMaterials.id)))
        .where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, subjectID), eq(recallTargets.excluded, false), eq(recallTargets.retired, false), eq(recallMaterials.status, "ready"), eq(recallMaterials.revisionId, subject.revisionId), or(isNull(recallTargets.dueAt), lte(recallTargets.dueAt, new Date())))).orderBy(asc(recallTargets.dueAt), asc(recallTargets.id));
      const open = await tx.select().from(recallSessions).where(and(eq(recallSessions.userId, userId), eq(recallSessions.subjectId, subjectID), eq(recallSessions.finished, false)));
      const reserved = new Set(open.flatMap(s => jsonArray(s.state.queue).slice(Number(s.state.index ?? 0))));
      const available = candidates.filter(c => !reserved.has(c.target.id) && (!c.target.exposedAt || c.target.exposedAt.getTime() + 600_000 <= Date.now()) && (!conceptIDs || conceptIDs.has(stringValue(c.material.snapshot.conceptID)) || jsonArray(c.material.snapshot.relatedConceptIDs).some(id => typeof id === "string" && conceptIDs.has(id))));
      const due = available.filter(c => c.target.memory), fresh = available.filter(c => !c.target.memory).slice(0, 3);
      const eligible = [...due.slice(0, 8 - fresh.length), ...fresh];
      const state: JSONObject = { queue: eligible.map(c => c.target.id), index: 0, selection: asJSON(selection), episode: null, topicID, policyVersion: recallPolicyVersion, schedulerVersion };
      const row = requireValue((await tx.insert(recallSessions).values({ userId, subjectId: subjectID, state, finished: !eligible.length }).returning())[0]);
      return { session: asJSON(sessionDTO(await this.initializeEpisode(tx, row))) };
    });
  }
  async session(userId: string, id: string) { return requireValue((await this.db.select().from(recallSessions).where(and(eq(recallSessions.userId, userId), eq(recallSessions.id, id))))[0]); }
  async sessions(userId: string, subjectID: string, cursor?: string, limit = 50): Promise<Page<RecallSession>> {
    await ownedSubject(this.db, userId, subjectID);
    const rows = await this.db.select({ id: recallSessions.id, subjectId: recallSessions.subjectId, version: recallSessions.version, finished: recallSessions.finished,
      state: sql<JSONObject>`jsonb_build_object('topicID', ${recallSessions.state}->'topicID')`, updatedAt: recallSessions.updatedAt }).from(recallSessions)
      .where(and(eq(recallSessions.userId, userId), eq(recallSessions.subjectId, subjectID), cursor ? gt(recallSessions.id, cursor) : undefined)).orderBy(asc(recallSessions.id)).limit(limit + 1);
    return { items: rows.slice(0, limit).map(sessionDTO), nextCursor: rows.length > limit ? rows[limit - 1]!.id : null };
  }
  private async current(tx: Transaction | Database, session: Session) {
    const id = stringValue(jsonArray(session.state.queue)[Number(session.state.index ?? 0)]);
    const target = requireValue((await tx.select().from(recallTargets).where(and(eq(recallTargets.userId, session.userId), eq(recallTargets.subjectId, session.subjectId), eq(recallTargets.id, id))))[0]);
    const subject = await ownedSubject(tx, session.userId, session.subjectId);
    const material = requireValue((await tx.select().from(recallMaterials).where(and(eq(recallMaterials.userId, session.userId), eq(recallMaterials.subjectId, session.subjectId), eq(recallMaterials.id, target.materialId))))[0]);
    if (target.retired || target.excluded || material.status !== "ready" || material.revisionId !== subject.revisionId || target.signature !== material.signature) throw new DomainError("MATERIAL_CHANGED", "This question's saved material changed. Start a new practice session.", 409);
    return target;
  }
  async presentation(userId: string, id: string): Promise<RecallSessionPresentation> {
    const session = await this.session(userId, id), summary = await this.sessionSummary(session); if (session.finished) return { session: sessionDTO(session), question: null, summary };
    try {
      const target = await this.current(this.db, session), episode = jsonObject(session.state.episode ?? {});
      if (episode.question) await this.participants(this.db, session, episode.question as unknown as Question);
      const question = episode.question ?? asJSON(await this.selectQuestion(this.db, session, target));
      return { session: sessionDTO(session), targetID: target.id, question: question as JSONObject, summary, upcoming: await this.upcomingQuestions(session, question as unknown as Question) };
    } catch (error) { if (!(error instanceof DomainError) || !["MATERIAL_CHANGED", "QUESTION_UNAVAILABLE", "NOT_FOUND"].includes(error.code)) throw error; return { session: sessionDTO(session), question: null, summary, issue: { code: error.code, message: "Saved material changed. Your answers were kept. Finish this session and prepare Recall again." } }; }
  }
  // Read ahead without recording exposure or committing reviews. The session is
  // at most eight targets; integrated questions can consume several queue items.
  private async upcomingQuestions(session: Session, current: Question) {
    const state = structuredClone(session.state), seen = new Set(jsonArray(state.seenTargetIDs)), exposed = new Set<string>();
    const upcoming: JSONObject[] = [];
    const episode = jsonObject(state.episode ?? {}), first = jsonObject(jsonArray(episode.assessments)[0] ?? {});
    const now = new Date(stringValue(jsonObject(jsonArray(episode.turns)[0] ?? {}).submittedAt) || Date.now());
    if (!episode.disputed && !episode.sourceRevealed) for (const raw of jsonArray(first.additionalCredits)) {
      const extra = await this.additionalCreditTarget(this.db, session, jsonObject(raw), now);
      if (extra) seen.add(extra.id);
    }
    let previous = current;
    for (let index = Number(state.index ?? 0) + 1; index < jsonArray(state.queue).length; index++) {
      for (const criterion of previous.criteria) seen.add(criterion.unitKey);
      for (const raw of jsonArray(jsonObject(asJSON(previous.verification ?? {})).disclosures)) exposed.add(stringValue(jsonObject(raw).materialID));
      state.seenTargetIDs = [...seen]; state.index = index;
      if (seen.has(jsonArray(state.queue)[index]!)) continue;
      try {
        const candidate = { ...session, state }, target = await this.current(this.db, candidate);
        const question = await this.selectQuestion(this.db, candidate, target, exposed);
        upcoming.push({ index, episode: { targetID: target.id, signature: target.signature, question: asJSON(question), turns: [], assessments: [], sourceRevealed: false, disputed: false, effort: null } });
        previous = question;
      } catch (error) {
        if (!(error instanceof DomainError) || !["MATERIAL_CHANGED", "QUESTION_UNAVAILABLE", "NOT_FOUND"].includes(error.code)) throw error;
      }
    }
    return upcoming;
  }
  private async additionalCreditTarget(tx: Transaction | Database, session: Session, credit: JSONObject, now: Date, lock = false) {
    const query = tx.select().from(recallTargets).where(and(eq(recallTargets.userId, session.userId), eq(recallTargets.subjectId, session.subjectId), eq(recallTargets.id, stringValue(credit.targetID))));
    const extra = (await (lock ? query.for("update") : query))[0];
    const material = extra ? (await tx.select().from(recallMaterials).where(and(eq(recallMaterials.userId, session.userId), eq(recallMaterials.subjectId, session.subjectId), eq(recallMaterials.id, extra.materialId))))[0] : null;
    const subject = await ownedSubject(tx, session.userId, session.subjectId);
    if (!extra || !material || extra.version !== Number(credit.targetVersion) || extra.signature !== credit.signature || extra.retired || extra.excluded || material.status !== "ready" || material.revisionId !== subject.revisionId || extra.dueAt && extra.dueAt > now || extra.exposedAt && extra.exposedAt.getTime() + 600_000 > now.getTime()) return null;
    return extra;
  }
  private async sessionSummary(session: Session): Promise<RecallSessionSummary> {
    const events = await this.db.select().from(learningEvents).where(and(eq(learningEvents.userId, session.userId), eq(learningEvents.subjectId, session.subjectId), eq(learningEvents.sessionId, session.id)));
    const undone = new Set(events.filter(e => e.kind === "undo").map(e => e.relatedEventId));
    const summary = { completed: 0, independent: 0, supported: 0, needsPractice: 0, skipped: 0, additionalRecalled: 0 };
    for (const event of events) {
      if (undone.has(event.id) || event.relatedEventId && undone.has(event.relatedEventId)) continue;
      if (event.kind === "review" && event.payload.additionalCredit) { summary.additionalRecalled++; continue; }
      if (event.relatedEventId) continue;
      if (event.kind === "skip") { summary.skipped++; continue; }
      if (event.kind !== "review") continue;
      summary.completed++;
      const episode = jsonObject(event.payload.episode), assessments = jsonArray(episode.assessments).map(jsonObject), first = episode.initialOverride ? jsonObject(episode.initialOverride) : assessments[0], last = assessments[assessments.length - 1];
      if (first?.outcome === "correct" && !event.payload.recognition && !episode.sourceRevealed && !episode.disputed) summary.independent++;
      else if (last?.outcome === "correct") summary.supported++;
      else if (event.payload.rating !== null) summary.needsPractice++;
      else summary.skipped++;
    }
    return summary;
  }
  async reportQuestion(userId: string, id: string, operationID: string, version: number, reason: string) {
    return mutation(this.db, userId, operationID, { action: "reportRecallQuestion", id, version, reason }, async tx => {
      const initial = await this.session(userId, id); await ownedSubject(tx, userId, initial.subjectId, true);
      const session = requireValue((await tx.select().from(recallSessions).where(and(eq(recallSessions.userId, userId), eq(recallSessions.id, id))).for("update"))[0]); expected(session.version, version);
      const target = await this.current(tx, session), episode = jsonObject(session.state.episode);
      await tx.update(recallTargets).set({ excluded: true, data: { ...target.data, reportedIssue: reason }, version: target.version + 1 }).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, session.subjectId), eq(recallTargets.id, target.id)));
      await tx.insert(learningEvents).values({ userId, subjectId: session.subjectId, sessionId: id, targetId: target.id, kind: "skip", payload: { episode, reason, beforeMemory: target.memory, afterMemory: target.memory, policyVersion: recallPolicyVersion } });
      const index = Number(session.state.index ?? 0) + 1, finished = index >= jsonArray(session.state.queue).length;
      const state = { ...session.state, index, episode: null, lastEventID: null };
      await tx.update(recallSessions).set({ state, finished, version: version + 1, updatedAt: new Date() }).where(and(eq(recallSessions.userId, userId), eq(recallSessions.id, id)));
      await this.initializeEpisode(tx, { ...session, state, finished, version: version + 1 });
      await invalidate(tx, userId, "recall", session.subjectId, version + 1); return { version: version + 1 };
    });
  }
  async editPendingAnswer(userId: string, id: string, operationID: string, version: number) {
    return mutation(this.db, userId, operationID, { action: "editPendingAnswer", id, version }, async tx => {
      const initial = await this.session(userId, id); await ownedSubject(tx, userId, initial.subjectId, true);
      const session = requireValue((await tx.select().from(recallSessions).where(and(eq(recallSessions.userId, userId), eq(recallSessions.id, id))).for("update"))[0]); expected(session.version, version);
      const target = await this.current(tx, session);
      const episode = jsonObject(session.state.episode), turns = jsonArray(episode.turns);
      if (!episode.assessmentPending || !turns.length) throw new DomainError("ANSWER_NOT_PENDING", "This answer has already been assessed. Your saved answer was kept.", 409);
      const last = jsonObject(turns.pop()); episode.turns = turns; episode.assessmentPending = false;
      episode.draft = { answer: last.answer ?? "", inputValue: last.inputValue ?? null, input: last.input ?? { kind: "text" } };
      await tx.update(recallSessions).set({ state: { ...session.state, episode }, version: version + 1, updatedAt: new Date() }).where(and(eq(recallSessions.userId, userId), eq(recallSessions.id, id)));
      await tx.insert(learningEvents).values({ userId, subjectId: session.subjectId, sessionId: id, targetId: target.id, kind: "answerCorrection", payload: { targetID: episode.targetID ?? null, sessionVersion: version + 1 } });
      await invalidate(tx, userId, "recallSessions", session.subjectId, version + 1); return { version: version + 1 };
    });
  }
  async selfReportUnknown(userId: string, id: string, operationID: string, version: number) {
    return mutation(this.db, userId, operationID, { action: "selfReportUnknown", id, version }, async tx => {
      const initial = await this.session(userId, id); await ownedSubject(tx, userId, initial.subjectId, true);
      const session = requireValue((await tx.select().from(recallSessions).where(and(eq(recallSessions.userId, userId), eq(recallSessions.id, id))).for("update"))[0]); expected(session.version, version);
      const target = await this.current(tx, session), episode = jsonObject(session.state.episode), question = episode.question as unknown as Question;
      await this.participants(tx, session, question);
      if (episode.assessmentPending) throw new DomainError("ASSESSMENT_PENDING", "Complete or stop the pending assessment first.", 409);
      const turns = jsonArray(episode.turns), assessments = jsonArray(episode.assessments).map(jsonObject), last = assessments[assessments.length - 1], hadTurns = turns.length > 0;
      if (turns.length) {
        if (!last?.followUp) throw new DomainError("ANSWER_NOT_PENDING", "This question is already complete.", 409);
        last.followUp = null;
      } else {
        turns.push({ prompt: question.prompt, kind: "initial", answer: "I don't know.", inputValue: null, input: { kind: "text" }, inputKind: "text", submittedAt: new Date().toISOString() });
        assessments.push({ outcome: "incorrect", taskFairness: { status: "fair", reason: null, alternativeAnswer: null }, decisions: Object.fromEntries(question.criteria.map(c => [c.id, { status: "missing", evidenceQuotes: [], missingMeaning: c.requiredMeaning, completionTurn: null }])),
          contradictions: [], ambiguities: {}, feedback: "Review the answer below, then practise it again later.", followUp: null, sourceConcern: null, additionalCredits: [], policyVersion: recallPolicyVersion, model: "server:self-reported-unknown", assessedAt: new Date().toISOString() });
      }
      episode.turns = turns; episode.assessments = assessments; episode.assessmentPending = false; delete episode.draft;
      await tx.update(recallSessions).set({ state: { ...session.state, episode }, version: version + 1, updatedAt: new Date() }).where(and(eq(recallSessions.userId, userId), eq(recallSessions.id, id)));
      await tx.insert(learningEvents).values({ userId, subjectId: session.subjectId, sessionId: id, targetId: target.id, kind: hadTurns ? "followUpsStopped" : "selfReportedUnknown", payload: { episode, sessionVersion: version + 1 } });
      await invalidate(tx, userId, "recallSessions", session.subjectId, version + 1); return { version: version + 1 };
    });
  }
  async explain(userId: string, id: string, operationID: string, version: number, signal: AbortSignal) {
    const input = { action: "recallExplain", id, version }, previous = await completedOperation(this.db, userId, operationID, input); if (previous) return previous;
    const initial = await this.session(userId, id), reserved = await reserveOperation(this.db, userId, operationID, input, initial.subjectId);
    if (reserved.completed) return reserved.completed;
    const leaseID = requireValue(reserved.leaseID), controller = new AbortController(); let beating = false;
    const heartbeat = setInterval(() => {
      if (beating) return; beating = true;
      void heartbeatOperation(this.db, userId, operationID, leaseID).then(async () => { const current = await this.session(userId, id); if (current.finished || current.version !== version) controller.abort(); }).catch(() => controller.abort()).finally(() => { beating = false; });
    }, 10_000);
    try {
      expected(initial.version, version); await this.current(this.db, initial);
      const episode = jsonObject(initial.state.episode), question = episode.question as unknown as Question;
      if (!jsonArray(episode.assessments).length || episode.assessmentPending) throw new DomainError("ASSESSMENT_PENDING", "Complete the assessment before requesting an explanation.", 409);
      const material = requireValue((await this.db.select().from(recallMaterials).where(and(eq(recallMaterials.userId, userId), eq(recallMaterials.subjectId, initial.subjectId), eq(recallMaterials.id, stringValue(episode.targetID)))))[0]);
      const selection = selectionSchema.parse(initial.state.selection);
      if (selection.reasoning === "automatic") selection.reasoning = "medium";
      const output = await structured(this.ai, userId, selection, "recall_explanation",
        policies.recall_commonInstructions + " Explain the saved expected answer in clear, concise prose (at most 3 paragraphs). Use only its supplied facts and passages. Preserve qualifications. Do not assess the learner or add criteria, links, or follow-up questions.",
        { question: asJSON(question), material: material.snapshot }, z.strictObject({ explanation: z.string().trim().min(1).max(5000) }), AbortSignal.any([signal, controller.signal]), false);
      signal.throwIfAborted(); controller.signal.throwIfAborted();
      return await mutation(this.db, userId, operationID, input, async tx => {
        await ownedSubject(tx, userId, initial.subjectId, true);
        const latest = requireValue((await tx.select().from(recallSessions).where(and(eq(recallSessions.userId, userId), eq(recallSessions.id, id))).for("update"))[0]); expected(latest.version, version); const target = await this.current(tx, latest);
        await tx.update(recallSessions).set({ state: { ...latest.state, episode: { ...jsonObject(latest.state.episode), explanation: output.explanation } }, version: version + 1, updatedAt: new Date() }).where(and(eq(recallSessions.userId, userId), eq(recallSessions.id, id)));
        await tx.insert(learningEvents).values({ userId, subjectId: latest.subjectId, sessionId: id, targetId: target.id, kind: "explanation", payload: { explanation: output.explanation, sessionVersion: version + 1 } });
        await invalidate(tx, userId, "recallSessions", latest.subjectId, version + 1); return { version: version + 1, explanation: output.explanation };
      }, leaseID);
    } finally { clearInterval(heartbeat); controller.abort(); await releaseOperation(this.db, userId, operationID, leaseID); }
  }
  private async participants(tx: Transaction | Database, session: Session, question: Question) {
    const subject = await ownedSubject(tx, session.userId, session.subjectId), participants: Target[] = [];
    for (const id of [...new Set(question.criteria.map(c => c.unitKey))].sort()) {
      const target = requireValue((await tx.select().from(recallTargets).where(and(eq(recallTargets.userId, session.userId), eq(recallTargets.subjectId, session.subjectId), eq(recallTargets.id, id))))[0]);
      const material = requireValue((await tx.select().from(recallMaterials).where(and(eq(recallMaterials.userId, session.userId), eq(recallMaterials.subjectId, session.subjectId), eq(recallMaterials.id, target.materialId))))[0]);
      if (target.retired || target.excluded || material.status !== "ready" || material.revisionId !== subject.revisionId || target.signature !== material.signature) throw new DomainError("MATERIAL_CHANGED", "A participant in this question changed. Start a new practice session.", 409);
      if (question.targetSignatures?.[id] && question.targetSignatures[id] !== material.signature) throw new DomainError("MATERIAL_CHANGED", "A bound learning target changed. Prepare Recall again.", 409);
      if (question.criteria.filter(c => c.unitKey === id).some(c => c.evidenceIDs.some(eid => !jsonArray(material.snapshot.evidence).some(e => evidenceID(id, e) === eid)))) throw new DomainError("MATERIAL_CHANGED", "This question's evidence changed. Prepare Recall again.", 409);
      participants.push(target);
    }
    return participants;
  }
  private async selectQuestion(tx: Transaction | Database, session: Session, target: Target, exposedMaterials: Set<string> = new Set()) {
    const questions = verifiedQuestions(target).sort((a,b) => presentationPriority(b) - presentationPriority(a) || a.id.localeCompare(b.id));
    for (const question of questions) {
      if (contextIssue(question.prompt)) continue;
      question.prompt = displayPrompt(question.prompt);
      try {
        const participants = await this.participants(tx, session, question);
        for (const raw of jsonArray(jsonObject(asJSON(question.verification ?? {})).disclosures)) {
          const d = jsonObject(raw), disclosed = (await tx.select().from(recallTargets).where(and(eq(recallTargets.userId, session.userId), eq(recallTargets.subjectId, session.subjectId), eq(recallTargets.materialId, stringValue(d.materialID)))))[0];
          if (!disclosed || disclosed.signature !== d.signature || disclosed.retired) throw new DomainError("MATERIAL_CHANGED", "A question context changed.", 409);
        }
        if (participants.every(p => p.id === target.id || (jsonArray(session.state.queue).includes(p.id) && (!p.dueAt || p.dueAt <= new Date()) && !exposedMaterials.has(p.materialId) && (!p.exposedAt || p.exposedAt.getTime() + 600_000 <= Date.now()) && !jsonArray(session.state.seenTargetIDs).includes(p.id)))) return question;
      } catch (error) { if (!(error instanceof DomainError) || !["MATERIAL_CHANGED", "NOT_FOUND"].includes(error.code)) throw error; }
    }
    throw new DomainError("QUESTION_UNAVAILABLE", "No current question is available. Prepare Recall again.", 409);
  }
  private async initializeEpisode(tx: Transaction, session: Session): Promise<Session> {
    if (session.finished || session.state.episode) return session;
    const state = structuredClone(session.state), invalid = jsonArray(state.invalidTargetIDs);
    while (Number(state.index ?? 0) < jsonArray(state.queue).length) {
      const candidate = { ...session, state };
      try {
        const target = await this.current(tx, candidate), question = await this.selectQuestion(tx, candidate, target);
        const participants = await this.participants(tx, candidate, question);
        for (const raw of jsonArray(jsonObject(asJSON(question.verification ?? {})).disclosures)) {
          const disclosed = requireValue((await tx.select().from(recallTargets).where(and(eq(recallTargets.userId, session.userId), eq(recallTargets.subjectId, session.subjectId), eq(recallTargets.materialId, stringValue(jsonObject(raw).materialID)))))[0]);
          await this.recordExposure(tx, disclosed, session.id);
        }
        state.episode = { targetID: target.id, targetVersion: target.version, targetVersions: Object.fromEntries(participants.map(p => [p.id, p.version])), signature: target.signature, question: asJSON(question), turns: [], assessments: [], sourceRevealed: false, disputed: false, effort: null };
        state.invalidTargetIDs = invalid;
        await tx.update(recallSessions).set({ state }).where(eq(recallSessions.id, session.id)); return { ...session, state };
      } catch (error) { if (!(error instanceof DomainError) || !["MATERIAL_CHANGED", "NOT_FOUND", "QUESTION_UNAVAILABLE"].includes(error.code)) throw error; invalid.push(jsonArray(state.queue)[Number(state.index ?? 0)]!); state.index = Number(state.index ?? 0) + 1; }
    }
    state.invalidTargetIDs = invalid; await tx.update(recallSessions).set({ state, finished: true }).where(eq(recallSessions.id, session.id)); return { ...session, state, finished: true };
  }
  async answer(userId: string, id: string, operationID: string, version: number, answer: string, inputValue: JSONValue = null) {
    return mutation(this.db, userId, operationID, { action: "recallAnswer", id, version, answer, inputValue }, async tx => {
      const session = await this.session(userId, id); await ownedSubject(tx, userId, session.subjectId, true);
      const locked = requireValue((await tx.select().from(recallSessions).where(and(eq(recallSessions.id, id), eq(recallSessions.userId, userId))).for("update"))[0]); expected(locked.version, version);
      const target = await this.current(tx, locked), question = locked.state.episode ? jsonObject(locked.state.episode).question as unknown as Question : await this.selectQuestion(tx, locked, target);
      const participants = await this.participants(tx, locked, question);
      const episode = locked.state.episode ? jsonObject(locked.state.episode) : { targetID: target.id, targetVersion: target.version, targetVersions: Object.fromEntries(participants.map(p => [p.id, p.version])), signature: target.signature, question: asJSON(question), turns: [], assessments: [], sourceRevealed: false, disputed: false, effort: null };
      if (participants.some(p => Number(jsonObject(episode.targetVersions)[p.id]) !== p.version)) throw new DomainError("TARGET_CHANGED", "A target changed on another device. Your saved answer was kept.", 409);
      const turns = jsonArray(episode.turns), assessments = jsonArray(episode.assessments), last = assessments.length ? jsonObject(assessments[assessments.length - 1]) : null;
      if (episode.assessmentPending === true || (turns.length && !last?.followUp)) throw new DomainError("ASSESSMENT_PENDING", "Complete the pending assessment before adding another answer.", 409);
      const followUp = last?.followUp ? jsonObject(last.followUp) : null;
      const input = followUp ? followUp.input ? (await import("./recall-contracts.js")).answerInputSchema.parse(followUp.input) : { kind: "text" as const } : question.input;
      const rendered = renderAnswer(input, inputValue, answer);
      turns.push({ prompt: followUp?.prompt ?? question.prompt, kind: followUp?.kind ?? "initial", criterionID: followUp?.criterionID ?? null, answer: rendered, inputValue, input: asJSON(input), submittedAt: new Date().toISOString(), inputKind: input.kind }); episode.turns = turns; episode.assessmentPending = true; delete episode.draft;
      const state = { ...locked.state, episode };
      await tx.update(recallSessions).set({ state, version: version + 1, updatedAt: new Date() }).where(eq(recallSessions.id, id));
      await tx.insert(learningEvents).values({ userId, subjectId: session.subjectId, sessionId: id, targetId: target.id, kind: "answer", payload: { turn: turns[turns.length - 1]!, question: episode.question ?? null, sessionVersion: version + 1 } });
      await invalidate(tx, userId, "recallSessions", session.subjectId, version + 1); return { version: version + 1 };
    });
  }
  async assess(userId: string, id: string, operationID: string, version: number, signal: AbortSignal, dispute: string | null = null, disputeScope: "initial" | "conversation" = "initial") {
    const previous = await completedOperation(this.db, userId, operationID, { action: "recallAssess", id, version, dispute, disputeScope }); if (previous) return previous;
    const initial = await this.session(userId, id);
    const reserved = await reserveOperation(this.db, userId, operationID, { action: "recallAssess", id, version, dispute, disputeScope }, initial.subjectId);
    if (reserved.completed) return reserved.completed;
    const leaseID = requireValue(reserved.leaseID), controller = new AbortController(); let beating = false;
    const heartbeat = setInterval(() => { if (beating) return; beating = true; void heartbeatOperation(this.db, userId, operationID, leaseID).then(async () => { const current = await this.session(userId, id); if (current.finished || current.version !== version) controller.abort(); }).catch(() => controller.abort()).finally(() => { beating = false; }); }, 15_000);
    try { return await this.assessReserved(userId, id, operationID, version, AbortSignal.any([signal, controller.signal]), dispute, disputeScope, leaseID); }
    finally { clearInterval(heartbeat); await releaseOperation(this.db, userId, operationID, leaseID); }
  }
  private async assessReserved(userId: string, id: string, operationID: string, version: number, signal: AbortSignal, dispute: string | null, disputeScope: "initial" | "conversation", leaseID: string) {
    const session = await this.session(userId, id); expected(session.version, version);
    const target = await this.current(this.db, session), episode = jsonObject(session.state.episode);
    const { id: questionID, verified: _verified, verification: _verification, designVersion: _designVersion, preparationModel: _preparationModel, evidenceCatalog: _evidenceCatalog, targetSignatures, ...questionFields } = jsonObject(episode.question);
    const question = { ...questionSchema.parse(questionFields), id: stringValue(questionID), targetSignatures: jsonObject(targetSignatures) as Record<string, string> };
    const participants = await this.participants(this.db, session, question as Question);
    if (participants.some(p => Number(jsonObject(episode.targetVersions)[p.id]) !== p.version)) throw new DomainError("TARGET_CHANGED", "A target changed on another device. Your answer was kept.", 409);
    const allTurns = jsonArray(episode.turns).map(jsonObject), turns = dispute && disputeScope === "initial" ? allTurns.slice(0, 1) : allTurns, assessments = jsonArray(episode.assessments), ids = question.criteria.map(c => c.id);
    if (!turns.length) throw new DomainError("ANSWER_REQUIRED", "Save an answer before requesting assessment.");
    if (episode.assessmentPending !== true && !dispute) return mutation(this.db, userId, operationID, { action: "recallAssess", id, version, dispute, disputeScope }, async () => ({ version: session.version, assessment: assessments[assessments.length - 1] ?? null }), leaseID);
    if (Number(episode.targetVersion) !== target.version) throw new DomainError("TARGET_CHANGED", "This target was reviewed or changed on another device. Your answer was kept.", 409);
    const remaining = dispute ? 0 : Math.max(0, 2 - (turns.length - 1)), used = new Set(turns.slice(1).map(t => t.criterionID));
    const selection = jsonObject(session.state.selection) as unknown as AISelection;
    const objective = objectiveAssessment(question as Question, episode);
    const extras = !objective && !dispute && turns.length === 1 && !episode.sourceRevealed && !episode.disputed && !["choice", "matching"].includes(stringValue(turns[0]?.inputKind)) ? await this.additionalCandidates(session, question as Question, stringValue(turns[0]?.answer)) : [];
    const materials = await this.db.select().from(recallMaterials).where(and(eq(recallMaterials.userId, userId), eq(recallMaterials.subjectId, session.subjectId)));
    const primaryEvidence = question.criteria.flatMap(c => {
      const unit = materials.find(m => m.id === c.unitKey);
      return c.evidenceIDs.flatMap(id => { const evidence = unit ? jsonArray(unit.snapshot.evidence).find(e => evidenceID(c.unitKey, e) === id) : null; return evidence ? [stringValue(jsonObject(evidence).quote).slice(0, 900)] : []; });
    });
    const gradingCriteria = question.criteria.map(c => ({ id: c.id, task: c.requestedPart, meaning: c.requiredMeaning, given: c.promptGivens ?? (c.givenQuote ? [c.givenQuote] : []), acceptedAnswers: c.acceptedExamples, evidence: c.evidenceIDs.flatMap(id => { const m = materials.find(m => m.id === c.unitKey), e = m ? jsonArray(m.snapshot.evidence).find(e => evidenceID(c.unitKey, e) === id) : null; return e ? [stringValue(jsonObject(e).quote).slice(0, 900)] : []; }) }));
    const input: JSONObject = { question: { prompt: question.prompt, criteria: asJSON(gradingCriteria), answerKey: question.input.kind === "text" ? null : asJSON(question.input) },
      turns: turns.map((t, index) => ({ index, prompt: t.prompt ?? "", kind: t.kind ?? "initial", answer: normalizedAnswer(stringValue(t.answer)), answerFormat: t.inputKind ?? "text" })),
      additionalCandidates: extras.map(e => ({ key: e.key, claim: e.claim, criteria: asJSON(e.question.criteria), expectedAnswer: e.question.expectedAnswer })), terminology: [], followUpsRemaining: remaining, followUpCriterionIDs: ids.filter(i => !used.has(i)), reconsideration: [...jsonArray(episode.disputes), ...(dispute ? [{ reason: dispute, scope: disputeScope }] : [])], reconsiderationScope: dispute ? disputeScope : null, priorAssessment: dispute && assessments.length ? jsonObject(disputeScope === "initial" ? episode.initialOverride ?? assessments[0] : assessments[assessments.length - 1]).decisions ?? null : null };
    let judgment: JSONObject | null = dispute ? null : objective;
    for (let attempt = 0; !judgment && attempt < 2; attempt++) {
      const result = await structured(this.ai, userId, selection, "recall_assessment", policies.recall_assessmentInstructions, input, judgmentSchema(ids, remaining > 0, extras.map(e => ({ key: e.key, criteria: e.question.criteria }))), signal, false, 1);
      const candidate = asJSON(result) as JSONObject, issues: string[] = [];
      if (Object.values(result.decisions).every(d => d.status === "met") && result.contradictions.length) issues.push("A contradiction of required meaning cannot coexist with complete credit for every criterion.");
      for (const criterionID of ids) {
        const d = result.decisions[criterionID]!, ambiguity = result.ambiguities[criterionID]!;
        if (d.status === "met" && (d.missingMeaning !== null || d.completionTurn === null || d.completionTurn >= turns.length || ambiguity.length || !d.evidenceQuotes.length)) issues.push("Met criteria need unambiguous learner evidence and the earliest valid completion turn.");
        if (d.status !== "met" && (!d.missingMeaning?.trim() || /^(null|nil|none|n\/a|nothing|no gap)$/i.test(d.missingMeaning))) issues.push("Non-met criteria require a substantive missing meaning.");
        if (d.evidenceQuotes.some(quote => quote.length > 400 || !turns.slice(0, (d.completionTurn ?? turns.length - 1) + 1).some(t => stringValue(t.answer).includes(quote)))) issues.push("Evidence quotes must be verbatim from the applicable learner turns.");
        if (ambiguity.length === 1 || (ambiguity.length && ambiguity[0] === ambiguity[1])) issues.push("Ambiguity requires two distinct plausible readings.");
      }
      if (result.sourceConcern && (result.sourceConcernEvidence.length !== 2 || result.sourceConcernEvidence[0] === result.sourceConcernEvidence[1] || result.sourceConcernEvidence.some(quote => !primaryEvidence.some(e => e.includes(quote))))) issues.push("A source concern requires two contradictory excerpts from the supplied primary evidence.");
      if (!result.sourceConcern && result.sourceConcernEvidence.length) issues.push("No source concern requires an empty evidence list.");
      const prior = jsonObject(input.priorAssessment ?? {}), demoted = ids.filter(id => jsonObject(prior[id] ?? {}).status === "met" && result.decisions[id]?.status !== "met");
      if (canonical(demoted.sort()) !== canonical(result.creditRetractions.map(r => r.criterionID).sort())) issues.push("Explain every previously met criterion now demoted exactly once, otherwise creditRetractions must be empty.");
      const follow = result.followUp;
      if (follow && (used.has(follow.criterionID) || !ids.includes(follow.criterionID) || remaining === 0 || outcome(candidate) === "correct" || result.sourceConcern || result.taskFairness.status !== "fair" || /^(?:are you sure|did you mean|do you mean|were you saying|what else|anything else)\b/i.test(follow.prompt))) issues.push("Follow-ups must target one permitted unresolved meaning without repetition or confirmation.");
      if (follow && (result.decisions[follow.criterionID]?.status !== "partial" && !result.ambiguities[follow.criterionID]?.length)) issues.push("Only substantive partial gaps or genuine ambiguity can receive a follow-up.");
      if (follow?.input?.kind === "matching" && follow.input.matches.some(m => m.criterionID !== follow.criterionID)) issues.push("A follow-up control may address only its own criterion.");
      if (!issues.length) { judgment = candidate; break; } input.validationIssues = issues; input.previousJudgment = candidate;
    }
    if (!judgment) throw new DomainError("INVALID_ASSESSMENT", "The assessment was inconsistent. Your answer was kept; retry to continue.");
    const accepted = judgment;
    if (objective && dispute && question.criteria.some(c => jsonObject(jsonObject(accepted.decisions)[c.id] ?? {}).status !== jsonObject(jsonObject(objective.decisions)[c.id] ?? {}).status)) {
      accepted.decisions = objective.decisions!; accepted.ambiguities = objective.ambiguities!; accepted.followUp = null;
      accepted.taskFairness = { status: "ambiguous", reason: "The reassessment disagrees with the saved answer key. Review the question against its source before recording a learning result.", alternativeAnswer: accepted.interpretedAnswer ?? null };
      accepted.feedback = "This question needs review against its saved answer key. No learning penalty will be recorded.";
    }
    const proposed = extras.filter(e => extraEvidence(jsonObject(accepted.additionalRecall)[e.key], e, stringValue(turns[0]?.answer)));
    if (proposed.length && !accepted.sourceConcern && jsonObject(accepted.taskFairness).status !== "answerGiven") {
      try {
        const confirmations = await structured(this.ai, userId, selection, "recall_extra_verify", policies.recall_commonInstructions + "\nIndependently verify optional recalled knowledge. The learner saw only prompt, never a candidate question. Decide each full proposition from the FIRST answer in its actual prompt context. Context may resolve referents but cannot supply new candidate knowledge. Require the correct relationship, category, direction, quantities and every requested list member. Shared words and unspoken inferences do not prove recall. met requires completionTurn=0, missingMeaning=null and 1–3 verbatim first-answer quotes. Prefer no award when unsure.",
          { prompt: turns[0]!.prompt ?? "", answer: turns[0]!.answer ?? "", candidates: asJSON(proposed.map(e => ({ key: e.key, claim: e.claim, criteria: e.question.criteria }))) }, z.strictObject({ confirmations: z.strictObject(Object.fromEntries(proposed.map(e => [e.key, extraDecisionSchema(e.question.criteria.map(c => c.id))]))) }), signal, false, 1);
        accepted.additionalCredits = asJSON(proposed.filter(e => extraEvidence(asJSON(confirmations.confirmations[e.key]), e, stringValue(turns[0]?.answer))).map(e => ({ ...e, verification: confirmations.confirmations[e.key], verificationPolicy: recallPolicyVersion })));
      } catch (error) { if (signal.aborted) throw error; /* Optional credit cannot discard a completed primary assessment. */ }
    }
    return mutation(this.db, userId, operationID, { action: "recallAssess", id, version, dispute, disputeScope }, async tx => {
      await ownedSubject(tx, userId, session.subjectId, true);
      const latest = requireValue((await tx.select().from(recallSessions).where(and(eq(recallSessions.id, id), eq(recallSessions.userId, userId))).for("update"))[0]); expected(latest.version, version);
      const fresh = await this.current(tx, latest); if (fresh.signature !== target.signature) throw new DomainError("MATERIAL_CHANGED", "This learning target changed.", 409);
      if ((await this.participants(tx, latest, question as Question)).some(p => Number(jsonObject(episode.targetVersions)[p.id]) !== p.version)) throw new DomainError("TARGET_CHANGED", "A target changed while this answer was assessed. Your answer was kept.", 409);
      const updated = jsonObject(latest.state.episode); updated.assessments = [...assessments, { ...accepted, outcome: outcome(accepted), policyVersion: recallPolicyVersion, assessedAt: new Date().toISOString() }]; updated.assessmentPending = false;
      updated.disputed = outcome(accepted) === "uncertain";
      if (dispute) { updated.disputes = [...jsonArray(updated.disputes), { reason: dispute, scope: disputeScope }]; if (disputeScope === "initial") updated.initialOverride = accepted; }
      await tx.update(recallSessions).set({ state: { ...latest.state, episode: updated }, version: version + 1, updatedAt: new Date() }).where(eq(recallSessions.id, id));
      await tx.insert(learningEvents).values({ userId, subjectId: session.subjectId, sessionId: id, targetId: target.id, kind: dispute ? "reassessment" : "assessment", payload: { assessment: accepted, dispute, disputeScope: dispute ? disputeScope : null, sessionVersion: version + 1 } });
      await invalidate(tx, userId, "recallSessions", session.subjectId, version + 1);
      return { version: version + 1, assessment: accepted, outcome: outcome(accepted) };
    }, leaseID);
  }
  private async additionalCandidates(session: Session, question: Question, answer: string): Promise<ExtraCandidate[]> {
    if (answer.trim().split(/\s+/u).length < 8 && !candidateQuantities(answer).size) return [];
    const subject = await ownedSubject(this.db, session.userId, session.subjectId), records = await snapshot(this.db, session.userId, session.subjectId), units = this.units(records);
    const primaryIDs = new Set(question.criteria.map(c => c.unitKey)), primary = units.filter(u => primaryIDs.has(u.key));
    const anchors = new Set(primary.flatMap(u => [stringValue(u.snapshot.conceptID), ...jsonArray(u.snapshot.relatedConceptIDs)]));
    const related = new Set(anchors);
    for (const u of units) if (jsonArray(u.snapshot.relatedConceptIDs).some(id => anchors.has(id))) for (const id of jsonArray(u.snapshot.relatedConceptIDs)) related.add(id);
    const topics = new Set(records.filter(r => r.kind === "placement" && anchors.has(stringValue(r.fields.conceptID))).map(r => r.fields.topicID));
    for (const r of records) if (r.kind === "placement" && topics.has(r.fields.topicID) && r.fields.topicID) related.add(stringValue(r.fields.conceptID));
    const sessions = await this.db.select().from(recallSessions).where(and(eq(recallSessions.userId, session.userId), eq(recallSessions.subjectId, session.subjectId), eq(recallSessions.finished, false)));
    const reserved = new Set(sessions.filter(s => s.id !== session.id).flatMap(s => jsonArray(s.state.queue).slice(Number(s.state.index ?? 0))));
    const materials = await this.db.select().from(recallMaterials).where(and(eq(recallMaterials.userId, session.userId), eq(recallMaterials.subjectId, session.subjectId), eq(recallMaterials.status, "ready"), eq(recallMaterials.revisionId, subject.revisionId)));
    const targets = await this.db.select().from(recallTargets).where(and(eq(recallTargets.userId, session.userId), eq(recallTargets.subjectId, session.subjectId), eq(recallTargets.excluded, false), eq(recallTargets.retired, false)));
    const result: ExtraCandidate[] = []; let bytes = 0;
    for (const unit of units.map(u => ({ unit: u, match: candidateMatch(stringValue(u.snapshot.statement), answer) })).sort((a, b) => b.match.rank - a.match.rank || a.unit.key.localeCompare(b.unit.key))) {
      const u = unit.unit, target = targets.find(t => t.materialId === u.materialID), material = materials.find(m => m.id === u.materialID);
      if (!target || !material || material.signature !== target.signature || primaryIDs.has(u.key) || reserved.has(target.id) || jsonArray(session.state.seenTargetIDs).includes(target.id) || target.dueAt && target.dueAt > new Date() || target.exposedAt && target.exposedAt.getTime() + 600_000 > Date.now() || !unit.match.relevant) continue;
      if (!related.has(stringValue(u.snapshot.conceptID)) && !unit.match.quantities || !mentionsSubject([stringValue(u.snapshot.conceptName), ...jsonArray(u.snapshot.aliases).map(stringValue)], question.prompt + " " + answer) || primary.some(p => stringValue(p.snapshot.statement).toLowerCase() === stringValue(u.snapshot.statement).toLowerCase())) continue;
      const q = verifiedQuestions(target).find(q => q.criteria.every(c => c.unitKey === u.key)); if (!q) continue;
      const candidate = { key: "extra" + (result.length + 1), targetID: target.id, targetVersion: target.version, signature: target.signature, claim: stringValue(u.snapshot.statement), question: q };
      const size = Buffer.byteLength(JSON.stringify({ claim: candidate.claim, criteria: q.criteria })); if (bytes + size > 4000) continue;
      result.push(candidate); bytes += size; if (result.length === 3) break;
    }
    return result;
  }
  async advance(userId: string, id: string, operationID: string, version: number, effort: "easy" | "someEffort" | "veryDifficult" | null, skip = false) {
    return mutation(this.db, userId, operationID, { action: "recallAdvance", id, version, effort, skip }, async tx => {
      const session = await this.session(userId, id); await ownedSubject(tx, userId, session.subjectId, true);
      const latest = requireValue((await tx.select().from(recallSessions).where(and(eq(recallSessions.id, id), eq(recallSessions.userId, userId))).for("update"))[0]); expected(latest.version, version);
      const target = await this.current(tx, latest), episode = latest.state.episode ? jsonObject(latest.state.episode) : {}, assessments = jsonArray(episode.assessments).map(jsonObject), turns = jsonArray(episode.turns).map(jsonObject), last = assessments[assessments.length - 1];
      if (!skip && Number(episode.targetVersion) !== target.version) throw new DomainError("TARGET_CHANGED", "This target changed on another device. Start a new session.", 409);
      if (!skip && (!last || last.followUp || episode.assessmentPending)) throw new DomainError("ASSESSMENT_PENDING", "Finish this question before committing its result.", 409);
      const question = episode.question as unknown as Question | undefined, participants = !skip && question ? await this.participants(tx, latest, question) : [target];
      const now = new Date(stringValue(turns[0]?.submittedAt) || Date.now()), eventID = randomUUID(), seen = new Set(jsonArray(latest.state.seenTargetIDs));
      // The root and every participating target form one review/undo group.
      for (const participant of [target, ...participants.filter(p => p.id !== target.id)]) {
        if (!skip && Number(jsonObject(episode.targetVersions)[participant.id]) !== participant.version) throw new DomainError("TARGET_CHANGED", "A target changed on another device. Your answer was kept.", 409);
        const projected = question ? assessments.map(a => projectedAssessment(a, question, participant.id)) : assessments;
        const first = episode.initialOverride && question ? projectedAssessment(jsonObject(episode.initialOverride), question, participant.id) : projected[0], final = projected[projected.length - 1];
        if (first && final && first.outcome !== "uncertain" && jsonObject(first.taskFairness).status === "fair") {
          for (const [criterionID, raw] of Object.entries(jsonObject(final.decisions))) { const decision = jsonObject(raw); if (decision.status === "met" && decision.completionTurn === 0) jsonObject(first.decisions)[criterionID] = decision; }
          first.outcome = outcome(first);
        }
        const rating = reviewRating(episode, first, final, turns, effort === "easy" && jsonObject(episode.initialOverride ?? assessments[0] ?? {}).outcome !== "correct" ? "someEffort" : effort, skip);
        const after = rating === null ? participant.memory : asJSON(scheduler.next(card(participant.memory, now), now, rating).card) as JSONObject;
        await tx.insert(learningEvents).values({ id: participant.id === target.id ? eventID : randomUUID(), userId, subjectId: latest.subjectId, sessionId: id, targetId: participant.id, kind: skip ? "skip" : "review", relatedEventId: participant.id === target.id ? null : eventID,
          payload: { episode, rating, recognition: ["choice", "slider", "ordering", "matching"].includes(stringValue(turns[0]?.inputKind)), supportedCorrect: final?.outcome === "correct", beforeMemory: participant.memory, afterMemory: after, afterTargetVersion: participant.version + 1, schedulerVersion, policyVersion: recallPolicyVersion } });
        await tx.update(recallTargets).set({ memory: after, dueAt: after ? new Date(stringValue(after.due)) : null, version: participant.version + 1 }).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, latest.subjectId), eq(recallTargets.id, participant.id)));
        seen.add(participant.id);
      }
      if (!skip && !episode.disputed && !episode.sourceRevealed) for (const raw of jsonArray(assessments[0]?.additionalCredits)) {
        const credit = jsonObject(raw), targetID = stringValue(credit.targetID);
        if (seen.has(targetID)) continue;
        const extra = await this.additionalCreditTarget(tx, latest, credit, now, true);
        if (!extra) continue;
        const rating = effort === "veryDifficult" ? Rating.Hard : Rating.Good, after = asJSON(scheduler.next(card(extra.memory, now), now, rating).card) as JSONObject;
        await tx.insert(learningEvents).values({ userId, subjectId: latest.subjectId, sessionId: id, targetId: extra.id, kind: "review", relatedEventId: eventID,
          payload: { episode, additionalCredit: credit, rating, recognition: false, supportedCorrect: true, beforeMemory: extra.memory, beforeExposedAt: extra.exposedAt?.toISOString() ?? null, afterMemory: after, afterTargetVersion: extra.version + 1, schedulerVersion, policyVersion: recallPolicyVersion } });
        await tx.update(recallTargets).set({ memory: after, dueAt: new Date(stringValue(after.due)), version: extra.version + 1, exposedAt: now }).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, latest.subjectId), eq(recallTargets.id, extra.id)));
        seen.add(extra.id);
      }
      const lastIndex = Number(latest.state.index ?? 0); let index = lastIndex + 1;
      while (index < jsonArray(latest.state.queue).length && seen.has(jsonArray(latest.state.queue)[index]!)) index++;
      const finished = index >= jsonArray(latest.state.queue).length;
      const state = { ...latest.state, index, seenTargetIDs: [...seen], episode: null, lastEventID: eventID, lastEpisode: episode, lastIndex, lastSeenTargetIDs: latest.state.seenTargetIDs ?? [] };
      await tx.update(recallSessions).set({ state, finished, version: version + 1, updatedAt: new Date() }).where(eq(recallSessions.id, id));
      const next = await this.initializeEpisode(tx, { ...latest, state, finished, version: version + 1 });
      await invalidate(tx, userId, "recall", latest.subjectId, version + 1); return { version: version + 1, finished: next.finished };
    });
  }
  async undo(userId: string, id: string, operationID: string, version: number) {
    return mutation(this.db, userId, operationID, { action: "recallUndo", id, version }, async tx => {
      const session = await this.session(userId, id); await ownedSubject(tx, userId, session.subjectId, true);
      const latest = requireValue((await tx.select().from(recallSessions).where(and(eq(recallSessions.id, id), eq(recallSessions.userId, userId))).for("update"))[0]); expected(latest.version, version);
      const eventID = stringValue(latest.state.lastEventID), event = requireValue((await tx.select().from(learningEvents).where(and(eq(learningEvents.userId, userId), eq(learningEvents.id, eventID))))[0]);
      const undone = await tx.select().from(learningEvents).where(and(eq(learningEvents.userId, userId), eq(learningEvents.relatedEventId, eventID), eq(learningEvents.kind, "undo")));
      if (undone.length) throw new DomainError("UNDO_UNAVAILABLE", "This result was already undone.", 409);
      const linked = await tx.select().from(learningEvents).where(and(eq(learningEvents.userId, userId), eq(learningEvents.subjectId, event.subjectId), eq(learningEvents.relatedEventId, eventID), eq(learningEvents.kind, "review")));
      const restored = jsonObject(latest.state.lastEpisode ?? {}), versions: JSONObject = {};
      for (const review of [event, ...linked]) {
        const target = requireValue((await tx.select().from(recallTargets).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, event.subjectId), eq(recallTargets.id, review.targetId))).for("update"))[0]);
        if (target.version !== Number(review.payload.afterTargetVersion)) throw new DomainError("UNDO_UNAVAILABLE", "A later change to a participating target prevents undoing this result.", 409);
        const memory = review.payload.beforeMemory ? jsonObject(review.payload.beforeMemory) : null;
        await tx.update(recallTargets).set({ memory, dueAt: memory ? new Date(stringValue(memory.due)) : null, ...(review.payload.additionalCredit ? { exposedAt: review.payload.beforeExposedAt ? new Date(stringValue(review.payload.beforeExposedAt)) : null } : {}), version: target.version + 1 }).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, event.subjectId), eq(recallTargets.id, target.id)));
        await tx.insert(learningEvents).values({ userId, subjectId: event.subjectId, sessionId: id, targetId: target.id, kind: "undo", relatedEventId: review.id, payload: {} });
        versions[target.id] = target.version + 1;
      }
      if (restored.question) { restored.targetVersions = versions; restored.targetVersion = versions[event.targetId] ?? 0; }
      for (const assessment of jsonArray(restored.assessments).map(jsonObject)) for (const credit of jsonArray(assessment.additionalCredits).map(jsonObject)) if (versions[stringValue(credit.targetID)]) credit.targetVersion = versions[stringValue(credit.targetID)]!;
      await tx.update(recallSessions).set({ state: { ...latest.state, index: latest.state.lastIndex ?? 0, seenTargetIDs: latest.state.lastSeenTargetIDs ?? [], episode: restored.question ? restored : null, lastEventID: null }, finished: false, version: version + 1, updatedAt: new Date() }).where(eq(recallSessions.id, id));
      await invalidate(tx, userId, "recall", event.subjectId, version + 1); return { version: version + 1 };
    });
  }
  async exclude(userId: string, subjectID: string, targetID: string, operationID: string, version: number, excluded: boolean) {
    return mutation(this.db, userId, operationID, { action: "excludeQuestion", subjectID, targetID, version, excluded }, async tx => {
      await ownedSubject(tx, userId, subjectID, true); const target = requireValue((await tx.select().from(recallTargets).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, subjectID), eq(recallTargets.id, targetID))).for("update"))[0]); expected(target.version, version);
      await tx.update(recallTargets).set({ excluded, version: version + 1 }).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, subjectID), eq(recallTargets.id, targetID)));
      await invalidate(tx, userId, "recall", subjectID, version + 1); return { version: version + 1 };
    });
  }
  async finishSession(userId: string, id: string, operationID: string, version: number) {
    return mutation(this.db, userId, operationID, { action: "finishRecallSession", id, version }, async tx => {
      const initial = await this.session(userId, id); await ownedSubject(tx, userId, initial.subjectId, true);
      const session = requireValue((await tx.select().from(recallSessions).where(and(eq(recallSessions.userId, userId), eq(recallSessions.id, id))).for("update"))[0]); expected(session.version, version);
      await tx.update(recallSessions).set({ finished: true, version: version + 1, updatedAt: new Date() }).where(eq(recallSessions.id, id));
      await invalidate(tx, userId, "recallSessions", session.subjectId, version + 1); return { version: version + 1, finished: true };
    });
  }
  async expose(userId: string, subjectID: string, targetID: string, operationID: string, version: number) {
    return mutation(this.db, userId, operationID, { action: "exposeRecall", subjectID, targetID, version }, async tx => {
      await ownedSubject(tx, userId, subjectID, true);
      const target = requireValue((await tx.select().from(recallTargets).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, subjectID), eq(recallTargets.id, targetID))).for("update"))[0]); expected(target.version, version);
      await this.recordExposure(tx, target);
      await invalidate(tx, userId, "recall", subjectID, version + 1); return { version: version + 1 };
    });
  }
  private async recordExposure(tx: Transaction, target: Target, sessionID: string | null = null) {
      const userId = target.userId, subjectID = target.subjectId, targetID = target.id, version = target.version;
      await tx.update(recallTargets).set({ exposedAt: new Date(), version: version + 1 }).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, subjectID), eq(recallTargets.id, targetID)));
      const sessions = await tx.select().from(recallSessions).where(and(eq(recallSessions.userId, userId), eq(recallSessions.subjectId, subjectID), eq(recallSessions.finished, false)));
      for (const session of sessions) {
        const episode = jsonObject(session.state.episode ?? {}), question = jsonObject(episode.question ?? {});
        if (!jsonArray(question.criteria).some(c => jsonObject(c).unitKey === targetID)) continue;
        const assessments = jsonArray(episode.assessments), last = assessments.length ? jsonObject(assessments[assessments.length - 1]) : null;
        if (!last || last.followUp || episode.assessmentPending) {
          episode.sourceRevealed = true;
        }
        episode.targetVersions = { ...jsonObject(episode.targetVersions), [targetID]: version + 1 };
        if (episode.targetID === targetID) episode.targetVersion = version + 1;
        await tx.update(recallSessions).set({ state: { ...session.state, episode }, version: session.version + 1, updatedAt: new Date() }).where(eq(recallSessions.id, session.id));
      }
      await tx.insert(learningEvents).values({ userId, subjectId: subjectID, sessionId: sessionID, targetId: targetID, kind: "exposure", payload: {} });
  }
  async reset(userId: string, subjectID: string, operationID: string, version: number) {
    return mutation(this.db, userId, operationID, { action: "resetProgress", subjectID, version }, async tx => {
      const subject = await ownedSubject(tx, userId, subjectID, true); expected(subject.version, version);
      await tx.update(recallTargets).set({ memory: null, dueAt: null, exposedAt: null, version: sql`${recallTargets.version}+1` }).where(and(eq(recallTargets.userId, userId), eq(recallTargets.subjectId, subjectID)));
      await tx.update(recallSessions).set({ finished: true, version: sql`${recallSessions.version}+1` }).where(and(eq(recallSessions.userId, userId), eq(recallSessions.subjectId, subjectID)));
      await invalidate(tx, userId, "recall", subjectID, version + 1); return { reset: true };
    });
  }
}
