import { readdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { prompts } from './core.mjs';
if (Number(process.versions.node.split('.')[0]) !== 24) throw new Error('Node.js 24 required');
for (const file of await readdir(new URL('.', import.meta.url))) if (file.endsWith('.mjs')) {
  const result = spawnSync(process.execPath, ['--check', fileURLToPath(new URL(file, import.meta.url))], { stdio: 'inherit' });
  if (result.status !== 0) process.exit(result.status ?? 1);
}
const bank = await prompts(); console.log(`Syntax and canonical prompt extraction complete (${Object.keys(bank.bodies).length} prompts). No model calls or tests were run.`);
