import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import pg from "pg";
import { createAuthService } from "./auth-service.ts";
import { loadConfig } from "./config.ts";
import { AuthError } from "./domain.ts";
import { handleAuthRequest } from "./http.ts";
import { createMemoryRepository, emptyMemory, type MemoryData, type MemorySession } from "./memory-repository.ts";
import { migrate } from "./migrate.ts";
import { createPgRepository } from "./pg-repository.ts";
import type { AuthRepository } from "./repository.ts";
import { createSmsSender } from "./sms.ts";

const config = readConfig();

function readConfig() {
  try {
    return loadConfig(process.env);
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}
const sms = createSmsSender(config.sms, fetch);
const sessionTtlMs = config.sessionTtlDays * 24 * 60 * 60 * 1000;

const repository = config.databaseUrl ? await openPostgres(config.databaseUrl) : openFile(config.dataFile);
const auth = createAuthService({
  repo: repository.repo,
  demo: config.demo,
  sms,
  codePepper: config.codePepper,
  sessionTtlMs,
  wechat:
    config.wechatAppId || config.wechatAppSecret
      ? { appId: config.wechatAppId, appSecret: config.wechatAppSecret }
      : null,
  googleClientIds: config.googleClientIds,
  googleClientSecret: config.googleClientSecret,
  googleRedirectUris: config.googleRedirectUris,
});

const server = createServer((req, res) => {
  void handleAuthRequest(auth, req, res, {
    ready: async () => {
      try {
        await repository.repo.ping();
      } catch {
        throw new AuthError("db_unavailable", "database is unavailable");
      }
    },
  });
});

server.listen(config.port, () => {
  const store = config.databaseUrl ? "postgres" : "file";
  const smsName = config.sms.provider || "unset";
  process.stdout.write(
    `sky auth listening on ${config.port} (${store}, demo=${config.demo}, sms=${smsName}, host=${config.apiHost})\n`,
  );
});

async function openPostgres(databaseUrl: string): Promise<{ repo: AuthRepository }> {
  const pool = new pg.Pool({ connectionString: databaseUrl, max: 10 });
  const repo = createPgRepository(
    { query: (text, params) => pool.query(text, params) },
    async (fn) => {
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        const result = await fn({ query: (text, params) => client.query(text, params) });
        await client.query("COMMIT");
        return result;
      } catch (error) {
        try {
          await client.query("ROLLBACK");
        } catch {
          // The original error is the one to surface.
        }
        throw error;
      } finally {
        client.release();
      }
    },
  );
  await migrate({ query: (text, params) => pool.query(text, params) });
  return { repo };
}

function openFile(dataFile: string): { repo: AuthRepository } {
  const data = readMemory(dataFile);
  const repo = createMemoryRepository(data, {
    onChange() {
      mkdirSync(dirname(dataFile), { recursive: true });
      writeFileSync(dataFile, `${JSON.stringify(data, null, 2)}\n`);
    },
  });
  return { repo };
}

function readMemory(path: string): MemoryData {
  if (!existsSync(path)) return emptyMemory();
  const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<MemoryData> & {
    sessions?: Array<Partial<MemorySession> & { token?: string; userId?: string; createdAt?: string }>;
  };
  const fallbackExpiry = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
  return {
    users: parsed.users ?? [],
    identities: parsed.identities ?? [],
    sessions: (parsed.sessions ?? []).flatMap((session) => {
      if (!session.token || !session.userId || !session.createdAt) return [];
      return [
        {
          token: session.token,
          userId: session.userId,
          createdAt: session.createdAt,
          expiresAt: session.expiresAt || fallbackExpiry,
        },
      ];
    }),
    records: parsed.records ?? [],
    phoneCodes: parsed.phoneCodes ?? [],
  };
}
