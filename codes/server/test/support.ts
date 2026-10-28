import { createSign, generateKeyPairSync, type JsonWebKey, type KeyObject } from "node:crypto";
import { PGlite } from "@electric-sql/pglite";
import { createAuthService, type AuthService } from "../src/auth-service.ts";
import { migrate } from "../src/migrate.ts";
import { createMemoryRepository, emptyMemory, type MemoryData } from "../src/memory-repository.ts";
import { createPgRepository } from "../src/pg-repository.ts";
import type { AuthRepository } from "../src/repository.ts";

export function clock(start: string) {
  let current = Date.parse(start);
  return {
    now: () => new Date(current),
    advance(ms: number) {
      current += ms;
    },
    set(iso: string) {
      current = Date.parse(iso);
    },
  };
}

export interface Backend {
  auth: AuthService;
  repo: AuthRepository;
  time: ReturnType<typeof clock>;
  reset: () => Promise<void>;
}

const start = "2026-01-01T00:00:00.000Z";

export function memoryBackend(): Backend {
  const data: MemoryData = emptyMemory();
  const time = clock(start);
  let cursor = 0;
  const repo = createMemoryRepository(data);
  const auth = createAuthService({
    repo,
    demo: true,
    now: time.now,
    newId: () => `id-${cursor++}`,
  });
  return {
    auth,
    repo,
    time,
    async reset() {
      cursor = 0;
      time.set(start);
      data.users = [];
      data.identities = [];
      data.sessions = [];
      data.records = [];
      data.phoneCodes = [];
    },
  };
}

export async function postgresBackend(): Promise<Backend> {
  const db = new PGlite();
  await db.waitReady;
  const sqlOf = (queryable: { query: (text: string, params?: unknown[]) => Promise<{ rows: Record<string, unknown>[] }> }) => ({
    query: (text: string, params?: unknown[]) => queryable.query(text, params),
  });
  const sql = sqlOf(db);
  await migrate(sql);
  await migrate(sql);
  const time = clock(start);
  let cursor = 0;
  const repo = createPgRepository(sql, (fn) => db.transaction((tx) => fn(sqlOf(tx))));
  const auth = createAuthService({
    repo,
    demo: true,
    now: time.now,
    newId: () => `id-${cursor++}`,
  });
  return {
    auth,
    repo,
    time,
    async reset() {
      cursor = 0;
      time.set(start);
      await db.query("TRUNCATE TABLE phone_codes, sessions, identities, owned_records, users CASCADE");
    },
  };
}

export function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function googleKey() {
  const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const jwk = publicKey.export({ format: "jwk" }) as JsonWebKey;
  jwk.kid = "test-key";
  jwk.alg = "RS256";
  jwk.use = "sig";
  return {
    privateKey,
    loadCerts: async () => [{ kid: "test-key", jwk }],
  };
}

export function signJwt(privateKey: KeyObject, payload: Record<string, unknown>, kid = "test-key"): string {
  const header = Buffer.from(JSON.stringify({ alg: "RS256", typ: "JWT", kid })).toString("base64url");
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const data = `${header}.${body}`;
  const signature = createSign("RSA-SHA256").update(data).sign(privateKey).toString("base64url");
  return `${data}.${signature}`;
}
