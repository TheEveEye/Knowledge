import { createApp } from "./app.js";
import { loadConfig } from "./config.js";

const config = loadConfig();
const app = createApp(config);
let shuttingDown = false;

async function shutdown(signal: string) {
  if (shuttingDown) return;
  shuttingDown = true;
  app.log.info({ signal }, "Shutting down");
  const deadline = setTimeout(() => process.exit(1), 25_000);
  deadline.unref();
  try {
    await app.close();
    clearTimeout(deadline);
  } catch {
    app.log.error("Graceful shutdown failed");
    process.exitCode = 1;
  }
}

process.once("SIGTERM", () => { void shutdown("SIGTERM"); });
process.once("SIGINT", () => { void shutdown("SIGINT"); });

try {
  await app.listen({ host: config.host, port: config.port });
  app.log.info({ revision: config.revision, version: config.version }, "Knowledge API started");
} catch {
  app.log.error("Knowledge API could not start");
  await app.close();
  process.exitCode = 1;
}
