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
export const locations = Object.fromEntries(['learningPlanInstructions', 'learningPlanReviewInstructions', 'designInstructions', 'designVerificationInstructions', 'assessmentInstructions'].map(name => [name, 'policies.ts']));
const policyKeys = { learningPlanInstructions: 'recall_learningPlanInstructions', learningPlanReviewInstructions: 'recall_learningPlanReviewInstructions', designInstructions: 'design_designInstructions', designVerificationInstructions: 'design_designVerificationInstructions', assessmentInstructions: 'recall_assessmentInstructions' };
export const sourceDir = process.env.RECALL_SOURCE_DIR ?? resolve(repo, 'packages/backend/src');
export async function prompts() {
  const source = await readFile(resolve(sourceDir, 'policies.ts'), 'utf8');
  const policies = Object.fromEntries([...source.matchAll(/"([^"\n]+)": ("(?:[^"\\]|\\.)*")/g)].map(m => [m[1], JSON.parse(m[2])]));
  const bodies = Object.fromEntries(Object.entries(policyKeys).map(([name, key]) => {
    if (typeof policies[key] !== 'string') throw new Error(`Cannot extract production policy ${key}`);
    return [name, policies[key]];
  }));
  return { common: '', bodies, sourceHashes: { 'policies.ts': hash(source) } };
}
export function replacePolicies(source, bodies) {
  for (const [name, key] of Object.entries(policyKeys)) {
    const pattern = new RegExp('("' + key + '": )' + /"(?:[^"\\]|\\.)*"/.source);
    if (!pattern.test(source)) throw new Error(`Canonical policy marker missing: ${key}`);
    source = source.replace(pattern, (_, prefix) => prefix + JSON.stringify(bodies[name]));
  }
  return source;
}
export function instruction(bank, name) { return bank.common + '\n' + bank.bodies[name]; }
export function validateCandidate(base, candidate) {
  if (Object.keys(candidate).sort().join() !== Object.keys(base.bodies).sort().join()) throw new Error('Prompt keys changed');
  for (const [key, value] of Object.entries(candidate)) {
    if (typeof value !== 'string' || value.length < 200 || value.length > Math.min(14000, Math.ceil(base.bodies[key].length * 1.10) + 300)) throw new Error('Invalid prompt length');
    if (/"""|\\\(|\u0000/.test(value)) throw new Error('Unsafe Swift prompt literal');
  }
}
