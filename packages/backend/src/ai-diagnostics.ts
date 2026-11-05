import { mkdir, readdir, rename, stat, unlink, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { randomUUID } from "node:crypto";
import { CredentialVault } from "./ai.js";

// Private operator diagnostics, encrypted with the existing server vault key. Never served by source routes.
export async function retainAIRejection(userId: string, requestID: string, record: Record<string, unknown>) {
  const folder = resolve(process.env.SOURCE_DIRECTORY ?? ".data/sources", ".ai-diagnostics", userId);
  await mkdir(folder, { recursive: true, mode: 0o700 });
  const target = join(folder, requestID + ".enc"), temporary = target + "." + randomUUID() + ".partial";
  const sealed = new CredentialVault().seal({ ...record, userId, requestID, createdAt: new Date().toISOString() }, "ai-diagnostic:" + userId + ":" + requestID);
  await writeFile(temporary, sealed, { mode: 0o600 });
  await rename(temporary, target);
  const entries = await Promise.all((await readdir(folder)).filter(n => /^[a-f0-9-]{36}\.enc$/.test(n)).map(async name => ({ name, time: (await stat(join(folder, name))).mtimeMs })));
  entries.sort((a,b) => b.time - a.time);
  await Promise.all(entries.filter((e,i) => i >= 100 || e.time < Date.now() - 7 * 86_400_000).map(e => unlink(join(folder, e.name))));
}
