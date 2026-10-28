import { AuthError, type Identity, type IdentityType, type OwnedRecord, type User } from "./domain.ts";
import { sha256Hex } from "./hash.ts";
import type { AuthRepository, NewSession, PhoneCodeRecord, StoredSession } from "./repository.ts";
import type { Sql } from "./sql.ts";

type Begin = <T>(fn: (tx: Sql) => Promise<T>) => Promise<T>;

export function createPgRepository(sql: Sql, begin: Begin): AuthRepository {
  return build(sql, begin);
}

function build(sql: Sql, begin: Begin | null): AuthRepository {
  const repo: AuthRepository = {
    async transaction(fn) {
      if (!begin) return fn(build(sql, null));
      return begin(async (tx) => fn(build(tx, null)));
    },

    async ping() {
      await sql.query("SELECT 1");
    },

    async findUser(id) {
      const result = await sql.query("SELECT * FROM users WHERE id = $1", [id]);
      const row = result.rows[0];
      return row ? mapUser(row) : null;
    },

    async insertUser(user) {
      await sql.query(
        `INSERT INTO users (
          id, created_at, display_name, email, retired_at, merged_into_user_id, merged_from_user_ids
        ) VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)`,
        [
          user.id,
          user.createdAt,
          user.displayName,
          user.email,
          user.retiredAt,
          user.mergedIntoUserId,
          JSON.stringify(user.mergedFromUserIds),
        ],
      );
    },

    async updateUser(user) {
      const result = await sql.query(
        `UPDATE users SET
          display_name = $2,
          email = $3,
          retired_at = $4,
          merged_into_user_id = $5,
          merged_from_user_ids = $6::jsonb
        WHERE id = $1
        RETURNING id`,
        [user.id, user.displayName, user.email, user.retiredAt, user.mergedIntoUserId, JSON.stringify(user.mergedFromUserIds)],
      );
      if (result.rows.length === 0) throw new AuthError("user_missing", "account does not exist");
    },

    async listUsers() {
      const result = await sql.query("SELECT * FROM users ORDER BY created_at, id");
      return result.rows.map(mapUser);
    },

    async findIdentity(type, providerSubject) {
      const result = await sql.query(
        "SELECT * FROM identities WHERE type = $1 AND provider_subject = $2",
        [type, providerSubject],
      );
      const row = result.rows[0];
      return row ? mapIdentity(row) : null;
    },

    async insertIdentity(identity) {
      try {
        await sql.query(
          `INSERT INTO identities (id, type, provider_subject, email, phone, user_id, created_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7)`,
          [
            identity.id,
            identity.type,
            identity.providerSubject,
            identity.email,
            identity.phone,
            identity.userId,
            identity.createdAt,
          ],
        );
      } catch (error) {
        if (isUniqueViolation(error)) throw new AuthError("identity_conflict", "identity already exists");
        throw error;
      }
    },

    async updateIdentityUser(id, userId) {
      await sql.query("UPDATE identities SET user_id = $2 WHERE id = $1", [id, userId]);
    },

    async listIdentitiesByUser(userId) {
      const result = await sql.query(
        "SELECT * FROM identities WHERE user_id = $1 ORDER BY created_at, id",
        [userId],
      );
      return result.rows.map(mapIdentity);
    },

    async listIdentities() {
      const result = await sql.query("SELECT * FROM identities ORDER BY created_at, id");
      return result.rows.map(mapIdentity);
    },

    async deleteIdentity(id) {
      await sql.query("DELETE FROM identities WHERE id = $1", [id]);
    },

    async insertSession(session: NewSession) {
      await sql.query(
        `INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES ($1, $2, $3, $4)`,
        [sha256Hex(session.token), session.userId, session.createdAt, session.expiresAt],
      );
    },

    async findSession(token) {
      const result = await sql.query("SELECT user_id, created_at, expires_at FROM sessions WHERE token_hash = $1", [
        sha256Hex(token),
      ]);
      const row = result.rows[0];
      if (!row) return null;
      const session: StoredSession = {
        userId: String(row.user_id),
        createdAt: asIso(row.created_at),
        expiresAt: asIso(row.expires_at),
      };
      return session;
    },

    async updateSessionUser(token, userId) {
      await sql.query("UPDATE sessions SET user_id = $2 WHERE token_hash = $1", [sha256Hex(token), userId]);
    },

    async deleteSession(token) {
      await sql.query("DELETE FROM sessions WHERE token_hash = $1", [sha256Hex(token)]);
    },

    async insertRecord(record) {
      await sql.query(
        "INSERT INTO owned_records (id, user_id, kind, payload) VALUES ($1, $2, $3, $4::jsonb)",
        [record.id, record.userId, record.kind, JSON.stringify(record.payload)],
      );
    },

    async listRecords() {
      const result = await sql.query("SELECT * FROM owned_records ORDER BY id");
      return result.rows.map(mapRecord);
    },

    async reassignUserData(fromUserId, toUserId) {
      await sql.query("UPDATE identities SET user_id = $2 WHERE user_id = $1", [fromUserId, toUserId]);
      await sql.query("UPDATE owned_records SET user_id = $2 WHERE user_id = $1", [fromUserId, toUserId]);
      await sql.query("UPDATE sessions SET user_id = $2 WHERE user_id = $1", [fromUserId, toUserId]);
    },

    async findPhoneCode(phone) {
      const result = await sql.query("SELECT * FROM phone_codes WHERE phone = $1 FOR UPDATE", [phone]);
      const row = result.rows[0];
      return row ? mapPhoneCode(row) : null;
    },

    async savePhoneCode(record) {
      await sql.query(
        `INSERT INTO phone_codes (phone, code_hash, expires_at, attempts, sent_at)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (phone) DO UPDATE SET
           code_hash = EXCLUDED.code_hash,
           expires_at = EXCLUDED.expires_at,
           attempts = EXCLUDED.attempts,
           sent_at = EXCLUDED.sent_at`,
        [record.phone, record.codeHash, record.expiresAt, record.attempts, record.sentAt],
      );
    },

    async setPhoneCodeAttempts(phone, attempts) {
      await sql.query("UPDATE phone_codes SET attempts = $2 WHERE phone = $1", [phone, attempts]);
    },

    async deletePhoneCode(phone) {
      await sql.query("DELETE FROM phone_codes WHERE phone = $1", [phone]);
    },
  };

  return repo;
}

function mapUser(row: Record<string, unknown>): User {
  return {
    id: String(row.id),
    createdAt: asIso(row.created_at),
    displayName: String(row.display_name ?? ""),
    email: String(row.email ?? ""),
    retiredAt: row.retired_at == null ? null : asIso(row.retired_at),
    mergedIntoUserId: row.merged_into_user_id == null ? null : String(row.merged_into_user_id),
    mergedFromUserIds: asStringArray(row.merged_from_user_ids),
  };
}

function mapIdentity(row: Record<string, unknown>): Identity {
  return {
    id: String(row.id),
    type: String(row.type) as IdentityType,
    providerSubject: String(row.provider_subject),
    email: row.email == null ? null : String(row.email),
    phone: row.phone == null ? null : String(row.phone),
    userId: String(row.user_id),
    createdAt: asIso(row.created_at),
  };
}

function mapRecord(row: Record<string, unknown>): OwnedRecord {
  return {
    id: String(row.id),
    userId: String(row.user_id),
    kind: String(row.kind),
    payload: asPayload(row.payload),
  };
}

function mapPhoneCode(row: Record<string, unknown>): PhoneCodeRecord {
  return {
    phone: String(row.phone),
    codeHash: String(row.code_hash),
    expiresAt: asIso(row.expires_at),
    attempts: Number(row.attempts ?? 0),
    sentAt: asIso(row.sent_at),
  };
}

function asIso(value: unknown): string {
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "string") {
    const parsed = new Date(value);
    if (Number.isNaN(parsed.getTime())) return value;
    return parsed.toISOString();
  }
  throw new Error("expected timestamp");
}

function asStringArray(value: unknown): string[] {
  if (Array.isArray(value)) return value.map((item) => String(item));
  if (typeof value === "string") {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map((item) => String(item)) : [];
  }
  return [];
}

function asPayload(value: unknown): Record<string, unknown> {
  if (typeof value === "string") {
    const parsed: unknown = JSON.parse(value);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed as Record<string, unknown>;
    return {};
  }
  if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
  return {};
}

function isUniqueViolation(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const code = "code" in error ? String((error as { code?: unknown }).code) : "";
  if (code === "23505") return true;
  const message = error instanceof Error ? error.message : "";
  return /duplicate key|unique constraint/i.test(message);
}
