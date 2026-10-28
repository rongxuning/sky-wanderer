export interface Sql {
  query<T = Record<string, unknown>>(text: string, params?: unknown[]): Promise<{ rows: T[] }>;
}

export async function runStatements(sql: Sql, script: string): Promise<void> {
  const stripped = script
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n");
  for (const statement of stripped.split(";")) {
    const text = statement.trim();
    if (text) await sql.query(text);
  }
}
