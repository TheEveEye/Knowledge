import { resolve } from 'node:path';
import { read, save, log } from './core.mjs';
export class ContentIssue extends Error { constructor(message, details = {}) { super(message); this.name = 'ContentIssue'; this.details = details; } }
export function validate(value, schema, path = '$') {
  if (schema.anyOf) {
    for (const branch of schema.anyOf) { try { validate(value, branch, path); return; } catch (e) { if (!(e instanceof ContentIssue)) throw e; } }
    throw new ContentIssue(`${path}: no supported schema alternative`);
  }
  if (schema.enum && !schema.enum.some(x => JSON.stringify(x) === JSON.stringify(value))) throw new ContentIssue(`${path}: unsupported enum value`);
  const types = schema.type ? [schema.type].flat() : [];
  const type = value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
  if (types.length && !types.includes(type) && !(type === 'number' && types.includes('integer') && Number.isInteger(value))) throw new ContentIssue(`${path}: expected ${types.join('|')}`);
  if (type === 'number' && !Number.isFinite(value)) throw new ContentIssue(`${path}: non-finite number`);
  if (type === 'array') {
    if (value.length < (schema.minItems ?? 0) || value.length > (schema.maxItems ?? Infinity)) throw new ContentIssue(`${path}: invalid array length`);
    if (schema.items) value.forEach((v, i) => validate(v, schema.items, `${path}[${i}]`));
  }
  if (type === 'object') {
    for (const key of schema.required ?? []) if (!Object.hasOwn(value, key)) throw new ContentIssue(`${path}: missing ${key}`);
    for (const [k, v] of Object.entries(value)) {
      if (schema.properties?.[k]) validate(v, schema.properties[k], `${path}.${k}`);
      else if (schema.additionalProperties === false) throw new ContentIssue(`${path}: unexpected ${k}`);
    }
  }
}
// Layout normalization only. Always return an exact span from the ORIGINAL source.
// No lowercasing, semantic substitution, punctuation deletion or fuzzy matching.
function mapped(text) {
  let normalized = '', offsets = [];
  for (let i = 0; i < text.length;) {
    const original = String.fromCodePoint(text.codePointAt(i)), end = i + original.length;
    const piece = original === '\u00ad' ? '' : /[\s\u0007]/u.test(original) ? ' ' : original.normalize('NFKC');
    for (const c of piece) {
      if (c === ' ' && (!normalized || normalized.endsWith(' '))) continue;
      normalized += c; for (let j = 0; j < c.length; j++) offsets.push([i, end]);
    }
    i = end;
  }
  if (normalized.endsWith(' ')) { normalized = normalized.slice(0, -1); offsets.pop(); }
  return { normalized, offsets };
}
export function sourceQuote(source, proposed) {
  if (typeof proposed !== 'string' || !proposed.trim()) return null;
  if (source.includes(proposed)) return proposed;
  const s = mapped(source), q = mapped(proposed).normalized;
  if (!q) return null;
  const index = s.normalized.indexOf(q); if (index < 0) return null;
  return source.slice(s.offsets[index][0], s.offsets[index + q.length - 1][1]);
}
export async function checkpoint(client, key, fn) {
  const path = resolve(client.dir, 'checkpoints', key + '.json');
  try { return (await read(path)).result; } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const result = await fn(); await save(path, { result }); return result;
}
export async function recoverItem(client, stage, key, fn, fallback) {
  try { return await fn(); }
  catch (error) {
    if (!(error instanceof ContentIssue)) throw error;
    await log(client.dir, 'item_skipped', { stage, key, reason: error.message, details: error.details });
    return fallback;
  }
}
