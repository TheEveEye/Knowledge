import { readFile, writeFile, mkdir, rename, appendFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
export const repo = process.env.RECALL_REPO_ROOT ?? resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
export const hash = x => createHash('sha256').update(typeof x === 'string' ? x : JSON.stringify(x)).digest('hex');
export async function save(path, data) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = path + '.' + process.pid + '.' + randomUUID() + '.tmp'; await writeFile(tmp, JSON.stringify(data, null, 2), { mode: 0o600 }); await rename(tmp, path);
}
export async function read(path) { return JSON.parse(await readFile(path, 'utf8')); }
export async function log(dir, event, data = {}) {
  await appendFile(resolve(dir, 'events.jsonl'), JSON.stringify({ time: new Date().toISOString(), event, ...data }) + '\n', { mode: 0o600 });
}
export const text = { type: 'string' }, bool = { type: 'boolean' }, num = { type: 'number' };
export const list = (items, minItems = 0, maxItems = 100) => ({ type: 'array', items, minItems, maxItems });
export const nullable = schema => ({ anyOf: [schema, { type: 'null' }] });
export const choice = values => ({ type: 'string', enum: values });
export const obj = properties => ({ type: 'object', properties, required: Object.keys(properties), additionalProperties: false });
export const keyed = (keys, value) => obj(Object.fromEntries(keys.map(k => [k, value])));
export const locations = {
  learningPlanInstructions: 'RecallLearningPlan.swift', learningPlanReviewInstructions: 'RecallLearningPlan.swift',
  designInstructions: 'RecallDesignAI.swift', designVerificationInstructions: 'RecallDesignAI.swift', assessmentInstructions: 'RecallAI.swift',
};
export const sourceDir = process.env.RECALL_SOURCE_DIR ?? resolve(repo, 'apps/ios/Knowledge/Recall');
export async function prompts() {
  const files = {};
  for (const file of new Set(['RecallAI.swift', ...Object.values(locations)])) files[file] = await readFile(resolve(sourceDir, file), 'utf8');
  function body(file, name) {
    const m = files[file].match(new RegExp('(?:private )?static let ' + name + ' = (?:commonInstructions \\+ )?"""\\n([\\s\\S]*?)\\n    """'));
    if (!m) throw new Error(`Cannot extract canonical prompt ${name}`);
    return m[1].split('\n').map(l => l.startsWith('    ') ? l.slice(4) : l).join('\n');
  }
  const common = body('RecallAI.swift', 'commonInstructions');
  return { common, bodies: Object.fromEntries(Object.entries(locations).map(([name, file]) => [name, body(file, name)])),
    sourceHashes: Object.fromEntries(Object.entries(files).map(([k, v]) => [k, hash(v)])) };
}
export function instruction(bank, name) { return bank.common + '\n' + bank.bodies[name]; }
export function validateCandidate(base, candidate) {
  if (Object.keys(candidate).sort().join() !== Object.keys(base.bodies).sort().join()) throw new Error('Prompt keys changed');
  for (const [key, value] of Object.entries(candidate)) {
    if (typeof value !== 'string' || value.length < 200 || value.length > Math.min(14000, Math.ceil(base.bodies[key].length * 1.10) + 300)) throw new Error('Invalid prompt length');
    if (/"""|\\\(|\u0000/.test(value)) throw new Error('Unsafe Swift prompt literal');
  }
}
