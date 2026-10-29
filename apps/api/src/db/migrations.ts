import { fileURLToPath } from "node:url";
import { readMigrationFiles } from "drizzle-orm/migrator";

export const migrationsFolder = fileURLToPath(new URL("../../drizzle/", import.meta.url));
export const bundledMigrations = readMigrationFiles({ migrationsFolder });

if (bundledMigrations.length === 0) {
  throw new Error("No database migrations are bundled");
}
