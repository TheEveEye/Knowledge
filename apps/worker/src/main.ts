import { runWorker } from "@knowledge/backend";
const controller = new AbortController();
for (const signal of ["SIGINT", "SIGTERM"] as const) process.once(signal, () => { controller.abort(); setTimeout(() => process.exit(1), 25_000).unref(); });
try { await runWorker(controller.signal); }
catch { process.stderr.write("Knowledge worker stopped unexpectedly\n"); process.exitCode = 1; }
