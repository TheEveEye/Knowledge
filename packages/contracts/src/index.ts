/** Version 1 wire types. Dates are ISO 8601 strings; UUIDs are lowercase strings. */
export const contractVersion = 1;
export const maximumSourceBytes = 25 * 1024 * 1024;
export const maximumSourceCharacters = 300_000;
export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };
export type JSONObject = { [key: string]: JSONValue };
export const entityKinds = ["concept", "fact", "connection", "topic", "placement", "contribution"] as const;
export type EntityKind = typeof entityKinds[number];
export type Funding = "chatgpt" | "api";
export interface AISelection { funding: Funding; connectionID: string | null; model: string; reasoning: string }
export interface Evidence { sourceID: string; segmentID: string; quote: string }
export interface LibraryEntity {
  id: string; subjectID: string; kind: EntityKind; fields: JSONObject;
  protectedFields: string[]; isRetired: boolean; redirectID: string | null;
}
export interface Subject {
  id: string; name: string; version: number; revisionID: string; createdAt: string; updatedAt: string;
}
export interface Page<T> { items: T[]; nextCursor: string | null }
export interface Mutation { operationID: string; expectedVersion: number }
export interface SourcePassage { id: string; page: number | null; section: string | null; text: string }
export interface Source {
  id: string; subjectID: string; title: string; kind: "pdf" | "text" | "markdown";
  digest: string; byteCount: number; status: "uploaded" | "ready" | "failed";
  error: string | null; archived: boolean; createdAt: string;
  reviewNotes?: string[];
}
export interface Revision {
  id: string; subjectID: string; parentID: string | null; operationID: string;
  origin: string; title: string; summary: string; createdAt: string;
  changes: EntityChange[]; undoesRevisionID: string | null;
  names?: Record<string, string>;
}
export interface EntityChange { before: LibraryEntity | null; after: LibraryEntity | null }
export const jobKinds = ["extract", "import", "prepareRecall", "prepareCommit", "prepareUndo"] as const;
export type JobKind = typeof jobKinds[number];
export type JobStatus = "queued" | "running" | "paused" | "blocked" | "failed" | "completed" | "cancelled";
export interface Job {
  id: string; subjectID: string; importID: string | null; sourceID: string | null; kind: JobKind; status: JobStatus;
  version: number; progress: JSONObject; error: string | null; createdAt: string; updatedAt: string;
  selection: AISelection | null;
}
export interface ImportDraft {
  id: string; subjectID: string; sourceID: string; baseRevisionID: string; version: number;
  status: "processing" | "review" | "saved"; draft: JSONObject; checkpoint: JSONObject;
  selection: AISelection; createdAt: string; updatedAt: string;
}
export interface APIError { code: string; message: string; requestID?: string }
export interface Invalidation { id: string; resource: string; subjectID: string | null; version: number }
export interface Model { id: string; name: string; reasoning: string[] }
export interface AIConnection { id: string; version: number; label: string; provider: "chatgpt"; status: string; revocationPending: boolean; createdAt: string; identity?: { name: string | null; email: string | null } | null }
export interface AccountPreferences { version: number; values: JSONObject }
export interface ImportEntryChange {
  id: string; selected?: boolean; name?: string; fields?: JSONObject; acceptMerge?: boolean;
  resolutionAction?: "apply" | "undo" | "dismiss" | "restore";
}
export interface ImportDraftSummary { id: string; subjectID: string; sourceID: string; version: number; status: string; updatedAt: string; sourceTitle: string; processing: boolean; jobStatus: JobStatus | null; activity: string }
export interface PendingDecision { id: string; subjectID: string; importID: string | null; state: JSONObject; version: number }
export interface RecallSession { id: string; subjectID: string; version: number; finished: boolean; state: JSONObject; updatedAt: string }
export interface RecallSessionSummary { completed: number; independent: number; supported: number; needsPractice: number; skipped: number; additionalRecalled: number }
export interface RecallSessionPresentation { session: RecallSession; question: JSONObject | null; summary: RecallSessionSummary; targetID?: string; issue?: { code: string; message: string } }
export interface RecallOverview {
  total: number; prepared: number; assessed: number; due: number; new: number; issues: number;
  materialPending: number; materialBlocked: number; contextMaterials: number; duplicateMaterials: number;
  nextDueAt: string | null; scopeName: string;
}
export interface RecallProficiency { units: number; assessedTargets: number; targetSlots: number; readinessSum: number }
export interface RecallTargetDisplay {
  id: string; version: number; excluded: boolean; dueAt: string | null; memory: JSONObject | null;
  assessed: boolean; isNew: boolean; due: boolean; issue: JSONValue;
}
export interface RecallMaterialDisplay {
  id: string; entityID: string; status: string; signature: string; snapshot: JSONObject;
  current: boolean; bank: JSONObject; target: RecallTargetDisplay | null;
}
export interface RecallDashboard {
  subjectID: string; due: number; total: number; unassessed: number; proficiency: Record<string, number | null>;
  proficiencyByConcept: Record<string, RecallProficiency>; proficiencyByTopic: Record<string, RecallProficiency>; overview: RecallOverview;
}
