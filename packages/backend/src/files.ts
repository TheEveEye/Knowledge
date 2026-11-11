import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, open, readFile, readdir, rename, stat, statfs, unlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { and, asc, desc, eq, gt, inArray, lt, or, sql } from "drizzle-orm";
import type { SourcePassage } from "@knowledge/contracts";
import { maximumSourceBytes, maximumSourceCharacters } from "@knowledge/contracts";
import type { Database, Transaction } from "./database.js";
import { DomainError, invalidate, mutation, ownedSubject, requireValue } from "./core.js";
import { fileCleanup, jobs, passages, sources } from "./schema.js";

export class FileStore {
  readonly root = resolve(process.env.SOURCE_DIRECTORY ?? ".data/sources");
  async capacity() { await mkdir(this.root, { recursive: true, mode: 0o700 }); const info = await statfs(this.root); return { availableBytes: info.bavail * info.bsize, totalBytes: info.blocks * info.bsize }; }
  path(key: string) { if (!/^[a-f0-9-]{36}$/.test(key)) throw new DomainError("INVALID_SOURCE", "Invalid source identifier."); return join(this.root, key); }
  async put(data: Buffer) {
    if (!data.length || data.length > maximumSourceBytes) throw new DomainError("SOURCE_TOO_LARGE", "Choose a nonempty file of at most 25 MiB.", 413);
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    const reserve = Number(process.env.SOURCE_DISK_RESERVE_BYTES ?? 536_870_912);
    if (!Number.isSafeInteger(reserve) || reserve < 0) throw new Error("Invalid SOURCE_DISK_RESERVE_BYTES");
    if ((await this.capacity()).availableBytes < reserve + data.length) throw new DomainError("STORAGE_FULL", "The server needs more storage before accepting this file.", 507);
    const key = randomUUID(), temporary = this.path(key) + ".partial";
    const file = await open(temporary, "wx", 0o600);
    try { await file.writeFile(data); await file.sync(); } finally { await file.close(); }
    await rename(temporary, this.path(key));
    const directory = await open(this.root, "r"); try { await directory.sync(); } finally { await directory.close(); }
    return { key, digest: createHash("sha256").update(data).digest("hex"), byteCount: data.length };
  }
  async remove(key: string) { try { await unlink(this.path(key)); } catch (error) { if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) throw error; } }
  async bytes(key: string) { return readFile(this.path(key)); }
  stream(key: string) { return createReadStream(this.path(key)); }
  async cleanup(db: Database) {
    // Backups take the exclusive form of this same advisory lock while copying bytes.
    await db.transaction(async tx => {
      await tx.execute(sql`SELECT pg_advisory_xact_lock_shared(782115903)`);
      const candidates = await tx.select().from(fileCleanup).where(lt(fileCleanup.after, new Date())).limit(100);
      for (const candidate of candidates) {
        if ((await tx.select({ id: sources.id }).from(sources).where(eq(sources.storageKey, candidate.storageKey))).length) continue;
        await this.remove(candidate.storageKey);
        await tx.delete(fileCleanup).where(eq(fileCleanup.storageKey, candidate.storageKey));
      }
    });
    // Failed HTTP requests can leave a finalized file before a database row exists.
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    const known = new Set((await db.select({ key: sources.storageKey }).from(sources)).map(s => s.key));
    for (const key of await readdir(this.root)) {
      if (!/^[a-f0-9-]{36}(\.partial)?$/.test(key) || known.has(key)) continue;
      const info = await stat(join(this.root, key));
      if (info.mtimeMs > Date.now() - 86_400_000) continue;
      if (key.endsWith(".partial")) await unlink(join(this.root, key));
      else await db.insert(fileCleanup).values({ storageKey: key, after: new Date(Date.now() + 86_400_000) }).onConflictDoNothing();
    }
  }
}
export async function extractPassages(bytes: Buffer, kind: string): Promise<SourcePassage[]> {
  let pages: string[];
  if (kind === "pdf") {
    const { getDocument, PasswordResponses } = await import("pdfjs-dist/legacy/build/pdf.mjs");
    const task = getDocument({ data: new Uint8Array(bytes), useSystemFonts: false });
    task.onPassword = (_update: (password: string) => void, reason: number) => { if (reason === PasswordResponses.NEED_PASSWORD || reason === PasswordResponses.INCORRECT_PASSWORD) void task.destroy(); };
    try {
      const pdf = await task.promise; pages = [];
      for (let page = 1; page <= pdf.numPages; page++) {
        const content = await (await pdf.getPage(page)).getTextContent();
        const text = content.items.map(item => "str" in item ? item.str + (item.hasEOL ? "\n" : " ") : "").join("").trim();
        if (!text) throw new DomainError("NEEDS_OCR", `Page ${page} has no selectable text. Import a searchable PDF.`);
        pages.push(text);
        if (pages.reduce((n, p) => n + p.length, 0) > maximumSourceCharacters) throw new DomainError("SOURCE_TOO_LONG", "Choose a source with at most 300,000 characters.");
      }
    } catch (error) {
      if (error instanceof DomainError) throw error;
      throw new DomainError("UNREADABLE_PDF", "This PDF is unreadable or password protected. Export an unlocked searchable PDF.");
    } finally { await task.destroy(); }
  } else {
    let encoding: "utf-8" | "utf-16le" | "utf-16be" = "utf-8";
    if (bytes[0] === 0xff && bytes[1] === 0xfe) encoding = "utf-16le";
    if (bytes[0] === 0xfe && bytes[1] === 0xff) encoding = "utf-16be";
    try { pages = [new TextDecoder(encoding, { fatal: true }).decode(bytes).replace(/^\uFEFF/, "")]; }
    catch { throw new DomainError("UNREADABLE_TEXT", "Use a UTF-8 or UTF-16 text file."); }
    if (pages[0]!.includes("\0")) throw new DomainError("UNREADABLE_TEXT", "This file contains binary data.");
  }
  if (!pages.join("").trim()) throw new DomainError("EMPTY_SOURCE", "This source has no readable text.");
  if (pages.reduce((n, page) => n + [...page].length, 0) > maximumSourceCharacters) throw new DomainError("SOURCE_TOO_LONG", "Choose a source with at most 300,000 characters.");
  const result: SourcePassage[] = [];
  let section: string | null = null;
  pages.forEach((page, index) => {
    // Match the native pipeline: keep headings and individual bullets addressable.
    for (const line of page.replace(/\r\n?/g, "\n").split("\n")) {
      if (!line.trim()) continue;
      const heading = line.trim();
      if (heading.startsWith("#") || (heading.length < 100 && /^(Module|Chapter|Unit|Section|Part)\s+/i.test(heading))) section = heading;
      let rest = Array.from(line);
      while (rest.length) {
        let end = Math.min(1800, rest.length);
        if (end < rest.length) {
          let space = end - 1; while (space > 900 && !/\s/u.test(rest[space]!)) space--;
          if (space > 900) end = space + 1;
        }
        const text = rest.slice(0, end).join(""); rest = rest.slice(end);
        result.push({ id: `p${index + 1}-s${result.length + 1}`, page: kind === "pdf" ? index + 1 : null, section, text });
      }
    }
  });
  return result;
}
export class SourceService {
  constructor(readonly db: Database, readonly files: FileStore) {}
  async upload(userId: string, subjectID: string, operationID: string, title: string, kind: "pdf" | "text" | "markdown", bytes: Buffer) {
    await ownedSubject(this.db, userId, subjectID);
    const digest = createHash("sha256").update(bytes).digest("hex");
    const stored = await this.files.put(bytes);
    // Keep unsuccessful/duplicate upload bytes for the delayed orphan sweep; never remove a committed source on an uncertain transaction result.
    return mutation(this.db, userId, operationID, { action: "upload", subjectID, title, kind, digest }, async tx => {
      await ownedSubject(tx, userId, subjectID, true);
      const source = requireValue((await tx.insert(sources).values({ userId, subjectId: subjectID, title, kind, storageKey: stored.key, digest, byteCount: stored.byteCount }).returning())[0]);
      await tx.insert(jobs).values({ userId, subjectId: subjectID, kind: "extract", input: { sourceID: source.id } });
      await invalidate(tx, userId, "sources", subjectID, 1);
      return { sourceID: source.id };
    });
  }
  async get(userId: string, id: string) {
    return requireValue((await this.db.select().from(sources).where(and(eq(sources.userId, userId), eq(sources.id, id))))[0]);
  }
  async list(userId: string, subjectID: string) {
    await ownedSubject(this.db, userId, subjectID);
    return this.db.select().from(sources).where(and(eq(sources.userId, userId), eq(sources.subjectId, subjectID))).orderBy(asc(sources.id));
  }
  async page(userId: string, subjectID: string, cursor?: string, limit = 50) {
    await ownedSubject(this.db, userId, subjectID);
    const rows = await this.db.select().from(sources).where(and(eq(sources.userId, userId), eq(sources.subjectId, subjectID), cursor ? gt(sources.id, cursor) : undefined)).orderBy(asc(sources.id)).limit(limit + 1);
    return { items: rows.slice(0, limit), nextCursor: rows.length > limit ? rows[limit - 1]!.id : null };
  }
  async readPassages(userId: string, sourceIDs: string[], query: string, segmentIDs: string[], offset: number, limit: number, match: "phrase" | "terms" = "phrase") {
    if (!sourceIDs.length) return { items: [], nextOffset: null };
    if (!Number.isSafeInteger(offset) || offset < 0 || query.length > 500 || segmentIDs.length > 24 || (segmentIDs.length && sourceIDs.length !== 1)) throw new DomainError("INVALID_TOOL", "Use one source for specific passage IDs and a valid search offset.");
    // Conversational questions rarely occur verbatim in lecture notes. Rank
    // lexical matches for chat while preserving literal search for other callers.
    const stopWords = new Set("a an and are as at be can could do does for from how i in is it me of on or please that the these this to was what when where which who why with would you your about tell explain have has det den de en ett och att som vad hur kan med om till av på är jag du mig vi ni man finns material course notes subject".split(" "));
    const terms = match === "terms" ? [...new Set((query.toLocaleLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []).filter(t => t.length > 1 && !stopWords.has(t)))].slice(0, 16) : [];
    const literal = sql`${passages.text} ILIKE ${"%" + query.replace(/[\\%_]/g, "\\$&") + "%"}`;
    const matches = terms.map(term => sql`${passages.text} ILIKE ${"%" + term + "%"}`);
    const score = matches.length ? sql`(${sql.join(matches.map(value => sql`CASE WHEN ${value} THEN 1 ELSE 0 END`), sql` + `)})` : sql`0`;
    const rows = await this.db.select().from(passages).where(and(eq(passages.userId, userId), inArray(passages.sourceId, sourceIDs),
      segmentIDs.length ? inArray(passages.id, segmentIDs) : undefined,
      query.trim() ? (matches.length ? or(literal, ...matches) : literal) : undefined))
      .orderBy(...(matches.length ? [desc(score)] : []), asc(passages.sourceId), asc(passages.ordinal)).offset(offset).limit(limit + 1);
    return { items: rows.slice(0, limit).map(p => ({ sourceID: p.sourceId, id: p.id, page: p.page, section: p.section, text: p.text,
      citationURL: "knowledge-source://" + p.sourceId + "/" + encodeURIComponent(p.id) })), nextOffset: rows.length > limit ? offset + limit : null };
  }
  async passages(userId: string, id: string, cursor = -1, limit = 100) {
    await this.get(userId, id);
    const rows = await this.db.select().from(passages).where(and(eq(passages.userId, userId), eq(passages.sourceId, id), sql`${passages.ordinal} > ${cursor}`)).orderBy(asc(passages.ordinal)).limit(limit + 1);
    return { items: rows.slice(0, limit).map(p => ({ id: p.id, page: p.page, section: p.section, text: p.text })), nextCursor: rows.length > limit ? String(rows[limit - 1]!.ordinal) : null };
  }
}
export async function storePassages(tx: Transaction, userId: string, subjectId: string, sourceId: string, values: SourcePassage[]) {
  await tx.delete(passages).where(and(eq(passages.userId, userId), eq(passages.sourceId, sourceId)));
  for (let offset = 0; offset < values.length; offset += 100) await tx.insert(passages).values(values.slice(offset, offset + 100).map((p, i) => ({ ...p, userId, subjectId, sourceId, ordinal: offset + i })));
  await tx.update(sources).set({ status: "ready", error: null }).where(and(eq(sources.userId, userId), eq(sources.id, sourceId)));
}
