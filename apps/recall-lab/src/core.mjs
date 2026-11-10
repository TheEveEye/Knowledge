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
export const policyFile = 'policies.json';
const policyKeys = { learningPlanInstructions: 'recall_learningPlanInstructions', learningPlanReviewInstructions: 'recall_learningPlanReviewInstructions', designInstructions: 'design_designInstructions', designVerificationInstructions: 'design_designVerificationInstructions', assessmentInstructions: 'recall_assessmentInstructions' };
export const locations = Object.fromEntries(Object.keys(policyKeys).map(name => [name, policyFile]));
export const sourceDir = process.env.RECALL_SOURCE_DIR ?? resolve(repo, 'packages/backend/src');
function parsePolicies(source) {
  const policies = JSON.parse(source);
  if (!policies || typeof policies !== 'object' || Array.isArray(policies)
    || Object.values(policies).some(lines => !Array.isArray(lines) || lines.some(line => typeof line !== 'string'))) {
    throw new Error('Canonical policies must be an object of prompt line arrays');
  }
  return policies;
}
export async function prompts() {
  const source = await readFile(resolve(sourceDir, policyFile), 'utf8');
  const policies = parsePolicies(source);
  const bodies = Object.fromEntries(Object.entries(policyKeys).map(([name, key]) => {
    if (!Array.isArray(policies[key])) throw new Error(`Cannot extract production policy ${key}`);
    return [name, policies[key].join('\n')];
  }));
  return { common: '', bodies, sourceHashes: { [policyFile]: hash(source) } };
}
export function replacePolicies(source, bodies) {
  const policies = parsePolicies(source);
  for (const [name, key] of Object.entries(policyKeys)) {
    if (!Object.hasOwn(policies, key)) throw new Error(`Canonical policy missing: ${key}`);
    if (typeof bodies[name] !== 'string') throw new Error(`Prompt body missing: ${name}`);
    policies[key] = bodies[name].split('\n');
  }
  return JSON.stringify(policies, null, 2) + '\n';
}
export function instruction(bank, name) { return bank.common + '\n' + bank.bodies[name]; }
export function validateCandidate(base, candidate) {
  if (Object.keys(candidate).sort().join() !== Object.keys(base.bodies).sort().join()) throw new Error('Prompt keys changed');
  for (const [key, value] of Object.entries(candidate)) {
    if (typeof value !== 'string' || value.length < 200 || value.length > Math.min(14000, Math.ceil(base.bodies[key].length * 1.10) + 300)) throw new Error('Invalid prompt length');
    if (value.includes('\u0000')) throw new Error('Invalid prompt content');
  }
}
