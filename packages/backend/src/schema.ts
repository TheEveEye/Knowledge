import { sql } from "drizzle-orm";
import { bigint, boolean, check, foreignKey, index, integer, jsonb, primaryKey, text, timestamp, unique, uuid } from "drizzle-orm/pg-core";
import type { AISelection, EntityChange, JSONObject, LibraryEntity } from "@knowledge/contracts";
import { knowledgeSchema as k, user } from "./auth-schema.js";
export * from "./auth-schema.js";

const owner = () => uuid("user_id").notNull().references(() => user.id, { onDelete: "cascade" });
const date = (name: string) => timestamp(name, { withTimezone: true }).defaultNow().notNull();
export const subjects = k.table("subjects", {
  id: uuid("id").defaultRandom().primaryKey(), userId: owner(), name: text("name").notNull(), normalizedName: text("normalized_name").notNull(),
  version: integer("version").default(1).notNull(), revisionId: uuid("revision_id").notNull(), createdAt: date("created_at"), updatedAt: date("updated_at"),
}, t => [unique("subjects_owner_id").on(t.userId, t.id), unique("subjects_owner_name").on(t.userId, t.normalizedName), index("subjects_owner_updated").on(t.userId, t.updatedAt)]);
export const sources = k.table("sources", {
  id: uuid("id").defaultRandom().primaryKey(), userId: owner(), subjectId: uuid("subject_id").notNull(), title: text("title").notNull(), kind: text("kind").notNull(),
  storageKey: text("storage_key").notNull().unique(), digest: text("digest").notNull(), byteCount: integer("byte_count").notNull(),
  status: text("status").default("uploaded").notNull(), error: text("error"), archived: boolean("archived").default(false).notNull(), createdAt: date("created_at"),
}, t => [unique("sources_owner_subject_id").on(t.userId, t.subjectId, t.id),
  foreignKey({ columns: [t.userId, t.subjectId], foreignColumns: [subjects.userId, subjects.id] }).onDelete("cascade"), index("sources_subject").on(t.userId, t.subjectId),
  check("source_size", sql`${t.byteCount} BETWEEN 0 AND 26214400`), check("source_kind", sql`${t.kind} IN ('pdf','text','markdown')`),
  check("source_status", sql`${t.status} IN ('uploaded','ready','failed')`)]);
export const passages = k.table("source_passages", {
  userId: owner(), subjectId: uuid("subject_id").notNull(), sourceId: uuid("source_id").notNull(), id: text("id").notNull(),
  ordinal: integer("ordinal").notNull(), page: integer("page"), section: text("section"), text: text("text").notNull(),
}, t => [primaryKey({ columns: [t.userId, t.sourceId, t.id] }),
  foreignKey({ columns: [t.userId, t.subjectId, t.sourceId], foreignColumns: [sources.userId, sources.subjectId, sources.id] }).onDelete("cascade"), index("passages_order").on(t.userId, t.sourceId, t.ordinal)]);
export const entities = k.table("library_entities", {
  id: uuid("id").notNull(), userId: owner(), subjectId: uuid("subject_id").notNull(), kind: text("kind").notNull(), record: jsonb("record").$type<LibraryEntity>().notNull(), updatedAt: date("updated_at"),
}, t => [primaryKey({ columns: [t.userId, t.subjectId, t.id] }),
  foreignKey({ columns: [t.userId, t.subjectId], foreignColumns: [subjects.userId, subjects.id] }).onDelete("cascade"), index("entities_kind").on(t.userId, t.subjectId, t.kind),
  check("entity_kind", sql`${t.kind} IN ('concept','fact','connection','topic','placement','contribution')`)]);
export const entityLinks = k.table("library_entity_links", {
  userId: owner(), subjectId: uuid("subject_id").notNull(), fromId: uuid("from_id").notNull(), toId: uuid("to_id").notNull(), field: text("field").notNull(),
}, t => [primaryKey({ columns: [t.userId, t.subjectId, t.fromId, t.toId, t.field] }),
  foreignKey({ columns: [t.userId, t.subjectId, t.fromId], foreignColumns: [entities.userId, entities.subjectId, entities.id] }).onDelete("cascade"),
  foreignKey({ columns: [t.userId, t.subjectId, t.toId], foreignColumns: [entities.userId, entities.subjectId, entities.id] }), index("entity_links_target").on(t.userId, t.subjectId, t.toId)]);
export const entityVersions = k.table("library_entity_versions", {
  userId: owner(), hash: text("hash").notNull(), payload: jsonb("payload").$type<LibraryEntity>().notNull(),
}, t => [primaryKey({ columns: [t.userId, t.hash] })]);
export const revisions = k.table("subject_revisions", {
  id: uuid("id").defaultRandom().primaryKey(), userId: owner(), subjectId: uuid("subject_id").notNull(), parentId: uuid("parent_id"), operationId: uuid("operation_id").notNull(),
  origin: text("origin").notNull(), title: text("title").notNull(), summary: text("summary").notNull(), manifest: jsonb("manifest").$type<Record<string, string>>().notNull(),
  changes: jsonb("changes").$type<EntityChange[]>().notNull(), undoesRevisionId: uuid("undoes_revision_id"), createdAt: date("created_at"),
}, t => [unique("revisions_owner_operation").on(t.userId, t.operationId), unique("revisions_owner_subject_id").on(t.userId, t.subjectId, t.id),
  foreignKey({ name: "revision_owned_parent", columns: [t.userId, t.subjectId, t.parentId], foreignColumns: [t.userId, t.subjectId, t.id] }),
  foreignKey({ name: "revision_owned_undo", columns: [t.userId, t.subjectId, t.undoesRevisionId], foreignColumns: [t.userId, t.subjectId, t.id] }),
  foreignKey({ columns: [t.userId, t.subjectId], foreignColumns: [subjects.userId, subjects.id] }).onDelete("cascade"), index("revisions_subject_created").on(t.userId, t.subjectId, t.createdAt)]);
export const aiConnections = k.table("ai_connections", {
  id: uuid("id").defaultRandom().primaryKey(), userId: owner(), provider: text("provider").default("chatgpt").notNull(), label: text("label").notNull(),
  version: integer("version").default(1).notNull(),
  status: text("status").default("active").notNull(), clientId: text("client_id").notNull(), providerSubject: text("provider_subject").notNull(),
  credentials: text("encrypted_credentials").notNull(), createdAt: date("created_at"), updatedAt: date("updated_at"),
}, t => [unique("ai_connections_owner_id").on(t.userId, t.id), index("ai_connections_owner").on(t.userId)]);
export const imports = k.table("imports", {
  id: uuid("id").defaultRandom().primaryKey(), userId: owner(), subjectId: uuid("subject_id").notNull(), sourceId: uuid("source_id").notNull(), baseRevisionId: uuid("base_revision_id").notNull(),
  version: integer("version").default(1).notNull(), status: text("status").default("processing").notNull(), draft: jsonb("draft").$type<JSONObject>().default({}).notNull(),
  checkpoint: jsonb("checkpoint").$type<JSONObject>().default({}).notNull(), selection: jsonb("selection").$type<AISelection>().notNull(), aiConnectionId: uuid("ai_connection_id"),
  createdAt: date("created_at"), updatedAt: date("updated_at"),
}, t => [unique("imports_owner_subject_id").on(t.userId, t.subjectId, t.id),
  foreignKey({ columns: [t.userId, t.subjectId, t.sourceId], foreignColumns: [sources.userId, sources.subjectId, sources.id] }),
  foreignKey({ columns: [t.userId, t.subjectId, t.baseRevisionId], foreignColumns: [revisions.userId, revisions.subjectId, revisions.id] }),
  foreignKey({ columns: [t.userId, t.aiConnectionId], foreignColumns: [aiConnections.userId, aiConnections.id] }), index("imports_subject").on(t.userId, t.subjectId)]);
export const jobs = k.table("processing_jobs", {
  id: uuid("id").defaultRandom().primaryKey(), userId: owner(), subjectId: uuid("subject_id").notNull(), importId: uuid("import_id"), kind: text("kind").notNull(),
  status: text("status").default("queued").notNull(), version: integer("version").default(1).notNull(), input: jsonb("input").$type<JSONObject>().notNull(),
  checkpoint: jsonb("checkpoint").$type<JSONObject>().default({}).notNull(), progress: jsonb("progress").$type<JSONObject>().default({}).notNull(),
  selection: jsonb("selection").$type<AISelection>(), aiConnectionId: uuid("ai_connection_id"), leaseId: uuid("lease_id"), leaseExpiresAt: timestamp("lease_expires_at", { withTimezone: true }),
  attempts: integer("attempts").default(0).notNull(), availableAt: date("available_at"), error: text("error"), updatedAt: date("updated_at"), createdAt: date("created_at"),
}, t => [foreignKey({ columns: [t.userId, t.subjectId], foreignColumns: [subjects.userId, subjects.id] }).onDelete("cascade"),
  foreignKey({ columns: [t.userId, t.subjectId, t.importId], foreignColumns: [imports.userId, imports.subjectId, imports.id] }).onDelete("cascade"),
  foreignKey({ columns: [t.userId, t.aiConnectionId], foreignColumns: [aiConnections.userId, aiConnections.id] }), index("jobs_claim").on(t.status, t.availableAt), index("jobs_subject").on(t.userId, t.subjectId),
  check("job_status", sql`${t.status} IN ('queued','running','paused','blocked','failed','completed','cancelled')`),
  check("job_kind", sql`${t.kind} IN ('extract','import','prepareRecall','prepareCommit','prepareUndo')`)]);
export const pendingDecisions = k.table("pending_library_decisions", {
  id: uuid("id").defaultRandom().primaryKey(), userId: owner(), subjectId: uuid("subject_id").notNull(), importId: uuid("import_id"),
  version: integer("version").default(1).notNull(), state: jsonb("state").$type<JSONObject>().notNull(),
}, t => [foreignKey({ columns: [t.userId, t.subjectId], foreignColumns: [subjects.userId, subjects.id] }).onDelete("cascade"),
  foreignKey({ name: "decision_owned_import", columns: [t.userId, t.subjectId, t.importId], foreignColumns: [imports.userId, imports.subjectId, imports.id] }), index("decisions_subject").on(t.userId, t.subjectId)]);
export const recallMaterials = k.table("recall_materials", {
  id: uuid("id").notNull(), userId: owner(), subjectId: uuid("subject_id").notNull(), entityId: uuid("entity_id").notNull(), signature: text("signature").notNull(),
  status: text("status").notNull(), snapshot: jsonb("snapshot").$type<JSONObject>().notNull(), bank: jsonb("bank").$type<JSONObject>().default({}).notNull(), revisionId: uuid("revision_id").notNull(), updatedAt: date("updated_at"),
}, t => [primaryKey({ columns: [t.userId, t.subjectId, t.id] }),
  foreignKey({ columns: [t.userId, t.subjectId, t.entityId], foreignColumns: [entities.userId, entities.subjectId, entities.id] }).onDelete("cascade"),
  foreignKey({ name: "recall_owned_revision", columns: [t.userId, t.subjectId, t.revisionId], foreignColumns: [revisions.userId, revisions.subjectId, revisions.id] }), index("recall_materials_entity").on(t.userId, t.subjectId, t.entityId)]);
export const recallTargets = k.table("recall_targets", {
  id: uuid("id").notNull(), userId: owner(), subjectId: uuid("subject_id").notNull(), materialId: uuid("material_id").notNull(), signature: text("signature").notNull(),
  data: jsonb("data").$type<JSONObject>().notNull(), memory: jsonb("memory").$type<JSONObject>(), dueAt: timestamp("due_at", { withTimezone: true }), exposedAt: timestamp("exposed_at", { withTimezone: true }),
  retired: boolean("retired").default(false).notNull(), excluded: boolean("excluded").default(false).notNull(), version: integer("version").default(1).notNull(),
}, t => [primaryKey({ columns: [t.userId, t.subjectId, t.id] }),
  foreignKey({ columns: [t.userId, t.subjectId, t.materialId], foreignColumns: [recallMaterials.userId, recallMaterials.subjectId, recallMaterials.id] }).onDelete("cascade"), index("recall_targets_due").on(t.userId, t.subjectId, t.dueAt)]);
export const recallSessions = k.table("recall_sessions", {
  id: uuid("id").defaultRandom().primaryKey(), userId: owner(), subjectId: uuid("subject_id").notNull(), version: integer("version").default(1).notNull(),
  finished: boolean("finished").default(false).notNull(), state: jsonb("state").$type<JSONObject>().notNull(), updatedAt: date("updated_at"),
}, t => [unique("recall_sessions_owner_subject_id").on(t.userId, t.subjectId, t.id), foreignKey({ columns: [t.userId, t.subjectId], foreignColumns: [subjects.userId, subjects.id] }).onDelete("cascade"), index("recall_sessions_subject").on(t.userId, t.subjectId)]);
export const learningEvents = k.table("learning_events", {
  id: uuid("id").defaultRandom().primaryKey(), userId: owner(), subjectId: uuid("subject_id").notNull(), sessionId: uuid("session_id"), targetId: uuid("target_id").notNull(),
  kind: text("kind").notNull(), relatedEventId: uuid("related_event_id"), payload: jsonb("payload").$type<JSONObject>().notNull(), createdAt: date("created_at"),
}, t => [foreignKey({ columns: [t.userId, t.subjectId, t.targetId], foreignColumns: [recallTargets.userId, recallTargets.subjectId, recallTargets.id] }).onDelete("cascade"),
  unique("learning_events_owner_subject_id").on(t.userId, t.subjectId, t.id),
  foreignKey({ name: "learning_event_owned_relation", columns: [t.userId, t.subjectId, t.relatedEventId], foreignColumns: [t.userId, t.subjectId, t.id] }),
  foreignKey({ columns: [t.userId, t.subjectId, t.sessionId], foreignColumns: [recallSessions.userId, recallSessions.subjectId, recallSessions.id] }), index("learning_events_target").on(t.userId, t.subjectId, t.targetId, t.createdAt)]);
export const preferences = k.table("user_preferences", { userId: owner().primaryKey(), version: integer("version").default(1).notNull(), values: jsonb("values").$type<JSONObject>().default({}).notNull() });
export const operations = k.table("application_operations", {
  userId: owner(), id: uuid("id").notNull(), fingerprint: text("fingerprint").notNull(), response: jsonb("response").$type<JSONObject>(), createdAt: date("created_at"),
  leaseId: uuid("lease_id"), leaseExpiresAt: timestamp("lease_expires_at", { withTimezone: true }),
  subjectId: uuid("subject_id"),
}, t => [primaryKey({ columns: [t.userId, t.id] }), foreignKey({ name: "operation_owned_subject", columns: [t.userId, t.subjectId], foreignColumns: [subjects.userId, subjects.id] }), index("operations_subject").on(t.userId, t.subjectId)]);
export const events = k.table("resource_events", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(), userId: owner(), resource: text("resource").notNull(), subjectId: uuid("subject_id"), version: integer("version").notNull(), createdAt: date("created_at"),
}, t => [index("resource_events_owner_cursor").on(t.userId, t.id)]);
export const aiRequests = k.table("ai_requests", {
  id: uuid("id").defaultRandom().primaryKey(), userId: owner(), connectionId: uuid("connection_id"), funding: text("funding").notNull(), model: text("model").notNull(), kind: text("kind").notNull(),
  reasoning: text("reasoning").default("automatic").notNull(), policyHash: text("policy_hash").default("legacy").notNull(),
  status: text("status").notNull(), inputTokens: integer("input_tokens").default(0).notNull(), outputTokens: integer("output_tokens").default(0).notNull(), leaseExpiresAt: timestamp("lease_expires_at", { withTimezone: true }).notNull(), createdAt: date("created_at"),
}, t => [foreignKey({ columns: [t.userId, t.connectionId], foreignColumns: [aiConnections.userId, aiConnections.id] }), index("ai_requests_admission").on(t.status, t.leaseExpiresAt), index("ai_requests_owner_usage").on(t.userId, t.createdAt)]);
export const workerHeartbeats = k.table("worker_heartbeats", { id: uuid("id").primaryKey(), updatedAt: date("updated_at"), revision: text("revision").notNull() });
export const serverState = k.table("server_state", { key: text("key").primaryKey(), value: text("value").notNull() });
export const fileCleanup = k.table("source_file_cleanup", { storageKey: text("storage_key").primaryKey(), after: date("after") });
