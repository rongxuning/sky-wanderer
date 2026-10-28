import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runStatements, type Sql } from "./sql.ts";

const migrationsDir = join(dirname(fileURLToPath(import.meta.url)), "../migrations");

export async function migrate(sql: Sql): Promise<void> {
  await sql.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
    id text PRIMARY KEY,
    applied_at timestamptz NOT NULL
  )`);
  const files = readdirSync(migrationsDir)
    .filter((name) => name.endsWith(".sql"))
    .sort();
  for (const file of files) {
    const applied = await sql.query<{ id: string }>("SELECT id FROM schema_migrations WHERE id = $1", [file]);
    if (applied.rows.length > 0) continue;
    const script = readFileSync(join(migrationsDir, file), "utf8");
    await runStatements(sql, script);
    await sql.query("INSERT INTO schema_migrations (id, applied_at) VALUES ($1, now())", [file]);
  }
}
