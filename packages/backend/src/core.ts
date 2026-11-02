import { createHash, randomUUID } from "node:crypto";
import { and, eq, gt, isNull, sql } from "drizzle-orm";
import type { JSONObject, JSONValue } from "@knowledge/contracts";
import type { Database, Transaction } from "./database.js";
import { events, operations, subjects } from "./schema.js";

export class DomainError extends Error {
  constructor(readonly code: string, message: string, readonly statusCode = 400) { super(message); }
}
export function requireValue<T>(value: T | null | undefined, message = "This item is unavailable."): T {
  if (value === null || value === undefined) throw new DomainError("NOT_FOUND", message, 404);
  return value;
}
export function canonical(value: unknown): string {
  if (value === undefined) throw new DomainError("INVALID_DATA", "A required value is missing.");
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  return "{" + Object.entries(value).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([key, item]) => JSON.stringify(key) + ":" + canonical(item)).join(",") + "}";
}
export const hash = (value: unknown) => createHash("sha256").update(canonical(value)).digest("hex");
export const normalizeName = (name: string) => name.normalize("NFKD").replace(/\p{M}/gu, "").trim().replace(/\s+/g, " ").toLocaleLowerCase("en-US");
export function expected(actual: number, version: number) {
  if (actual !== version) throw new DomainError("VERSION_CONFLICT", "This item changed on another device. Refresh and review your changes.", 409);
}
export async function ownedSubject(tx: Transaction | Database, userId: string, id: string, lock = false) {
  const query = tx.select().from(subjects).where(and(eq(subjects.userId, userId), eq(subjects.id, id)));
  const rows = lock ? await query.for("update") : await query;
  return requireValue(rows[0], "This subject is unavailable.");
}
export async function invalidate(tx: Transaction, userId: string, resource: string, subjectId: string | null, version: number) {
  await tx.insert(events).values({ userId, resource, subjectId, version });
}
export async function mutation<T extends JSONObject>(db: Database, userId: string, operationID: string, input: unknown, work: (tx: Transaction) => Promise<T>, leaseID?: string): Promise<T> {
  const fingerprint = hash(input);
  return db.transaction(async tx => {
    // Lock IDs are derived from bound values; collisions only reduce concurrency.
    await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${userId + ":" + operationID}, 0))`);
    const previous = (await tx.select().from(operations).where(and(eq(operations.userId, userId), eq(operations.id, operationID))))[0];
    if (previous) {
      if (previous.fingerprint !== fingerprint) throw new DomainError("OPERATION_REUSED", "This operation ID was already used for a different request.", 409);
      if (previous.response?.resourceDeleted === true) throw new DomainError("RESOURCE_DELETED", "This resource was deleted.", 410);
      if (previous.response) return previous.response as T;
      if (!leaseID || previous.leaseId !== leaseID || !previous.leaseExpiresAt || previous.leaseExpiresAt <= new Date()) throw new DomainError("OPERATION_PENDING", "This operation is still processing or its ownership changed. Your input was kept.", 409);
    }
    const response = await work(tx);
    const request = input && typeof input === "object" && !Array.isArray(input) ? input as Record<string, unknown> : {};
    const resource = response.subject && typeof response.subject === "object" && !Array.isArray(response.subject) ? response.subject : response.session && typeof response.session === "object" && !Array.isArray(response.session) ? response.session : {};
    const candidate = typeof request.subjectID === "string" ? request.subjectID : typeof resource.subjectID === "string" ? resource.subjectID : typeof resource.id === "string" && response.subject ? resource.id : null;
    const subjectId = candidate && (await tx.select({ id: subjects.id }).from(subjects).where(and(eq(subjects.userId, userId), eq(subjects.id, candidate))))[0] ? candidate : previous?.subjectId ?? null;
    if (previous) await tx.update(operations).set({ response, subjectId, leaseId: null, leaseExpiresAt: null }).where(and(eq(operations.userId, userId), eq(operations.id, operationID)));
    else await tx.insert(operations).values({ userId, id: operationID, fingerprint, response, subjectId });
    return response;
  });
}
export function jsonObject(value: unknown): JSONObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new DomainError("INVALID_DATA", "Expected an object.");
  return value as JSONObject;
}
export async function completedOperation(db: Database, userId: string, operationID: string, input: unknown) {
  const row = (await db.select().from(operations).where(and(eq(operations.userId, userId), eq(operations.id, operationID))))[0];
  if (!row) return null;
  if (row.fingerprint !== hash(input)) throw new DomainError("OPERATION_REUSED", "This operation ID was already used for a different request.", 409);
  if (row.response?.resourceDeleted === true) throw new DomainError("RESOURCE_DELETED", "This resource was deleted.", 410);
  if (row.response) return row.response;
  if (row.leaseExpiresAt && row.leaseExpiresAt > new Date()) throw new DomainError("OPERATION_PENDING", "This operation is still processing. Your input was kept; wait for its result or retry shortly.", 409);
  return null;
}
export async function reserveOperation(db: Database, userId: string, operationID: string, input: unknown, subjectId: string) {
  return db.transaction(async tx => {
    await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${userId + ":" + operationID}, 0))`);
    const previous = (await tx.select().from(operations).where(and(eq(operations.userId, userId), eq(operations.id, operationID))))[0], fingerprint = hash(input);
    if (previous && previous.fingerprint !== fingerprint) throw new DomainError("OPERATION_REUSED", "This operation ID was already used for a different request.", 409);
    if (previous?.response?.resourceDeleted === true) throw new DomainError("RESOURCE_DELETED", "This resource was deleted.", 410);
    if (previous?.response) return { completed: previous.response, leaseID: null };
    if (previous?.leaseExpiresAt && previous.leaseExpiresAt > new Date()) throw new DomainError("OPERATION_PENDING", "This operation is still processing. Your input was kept; retry shortly.", 409);
    const leaseID = randomUUID(), leaseExpiresAt = new Date(Date.now() + 60_000);
    if (previous) await tx.update(operations).set({ leaseId: leaseID, leaseExpiresAt }).where(and(eq(operations.userId, userId), eq(operations.id, operationID)));
    else await tx.insert(operations).values({ userId, id: operationID, subjectId, fingerprint, leaseId: leaseID, leaseExpiresAt });
    return { completed: null, leaseID };
  });
}
export async function heartbeatOperation(db: Database, userId: string, operationID: string, leaseID: string) {
  const rows = await db.update(operations).set({ leaseExpiresAt: new Date(Date.now() + 60_000) }).where(and(eq(operations.userId, userId), eq(operations.id, operationID), eq(operations.leaseId, leaseID), isNull(operations.response), gt(operations.leaseExpiresAt, new Date()))).returning({ id: operations.id });
  if (!rows.length) throw new DomainError("OPERATION_LEASE_LOST", "Operation ownership changed. Your answer was kept.", 409);
}
export async function releaseOperation(db: Database, userId: string, operationID: string, leaseID: string) {
  await db.update(operations).set({ leaseId: null, leaseExpiresAt: new Date() }).where(and(eq(operations.userId, userId), eq(operations.id, operationID), eq(operations.leaseId, leaseID), isNull(operations.response)));
}
export function jsonArray(value: JSONValue | undefined): JSONValue[] { return Array.isArray(value) ? value : []; }
export function stringValue(value: JSONValue | undefined): string { return typeof value === "string" ? value : ""; }
