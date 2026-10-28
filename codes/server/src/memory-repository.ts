import { AuthError, type Identity, type OwnedRecord, type User } from "./domain.ts";
import type { AuthRepository, NewSession, PhoneCodeRecord, StoredSession } from "./repository.ts";

export interface MemorySession extends StoredSession {
  token: string;
}

export interface MemoryData {
  users: User[];
  identities: Identity[];
  sessions: MemorySession[];
  records: OwnedRecord[];
  phoneCodes: PhoneCodeRecord[];
}

export function emptyMemory(): MemoryData {
  return { users: [], identities: [], sessions: [], records: [], phoneCodes: [] };
}

export function createMemoryRepository(data: MemoryData, options: { onChange?: () => void } = {}): AuthRepository {
  let depth = 0;

  function touch(): void {
    if (depth === 0) options.onChange?.();
  }

  function cloneUser(user: User): User {
    return structuredClone(user);
  }

  const repo: AuthRepository = {
    async transaction(fn) {
      depth += 1;
      const snap = structuredClone(data);
      try {
        const result = await fn(repo);
        if (depth === 1) options.onChange?.();
        return result;
      } catch (error) {
        data.users = snap.users;
        data.identities = snap.identities;
        data.sessions = snap.sessions;
        data.records = snap.records;
        data.phoneCodes = snap.phoneCodes;
        throw error;
      } finally {
        depth -= 1;
      }
    },

    async ping() {},

    async findUser(id) {
      const user = data.users.find((item) => item.id === id);
      return user ? cloneUser(user) : null;
    },

    async insertUser(user) {
      data.users.push(cloneUser(user));
      touch();
    },

    async updateUser(user) {
      const index = data.users.findIndex((item) => item.id === user.id);
      if (index < 0) throw new AuthError("user_missing", "account does not exist");
      data.users[index] = cloneUser(user);
      touch();
    },

    async listUsers() {
      return data.users.map(cloneUser);
    },

    async findIdentity(type, providerSubject) {
      const identity = data.identities.find((item) => item.type === type && item.providerSubject === providerSubject);
      return identity ? structuredClone(identity) : null;
    },

    async insertIdentity(identity) {
      const taken = data.identities.some(
        (item) => item.type === identity.type && item.providerSubject === identity.providerSubject,
      );
      if (taken) throw new AuthError("identity_conflict", "identity already exists");
      data.identities.push(structuredClone(identity));
      touch();
    },

    async updateIdentityUser(id, userId) {
      const identity = data.identities.find((item) => item.id === id);
      if (!identity) throw new AuthError("identity_not_found", "identity is not on this account");
      identity.userId = userId;
      touch();
    },

    async listIdentitiesByUser(userId) {
      return data.identities
        .filter((item) => item.userId === userId)
        .sort(byCreated)
        .map((item) => structuredClone(item));
    },

    async listIdentities() {
      return data.identities.slice().sort(byCreated).map((item) => structuredClone(item));
    },

    async deleteIdentity(id) {
      const index = data.identities.findIndex((item) => item.id === id);
      if (index >= 0) data.identities.splice(index, 1);
      touch();
    },

    async insertSession(session: NewSession) {
      data.sessions.push({ ...session });
      touch();
    },

    async findSession(token) {
      const session = data.sessions.find((item) => item.token === token);
      if (!session) return null;
      return { userId: session.userId, createdAt: session.createdAt, expiresAt: session.expiresAt };
    },

    async updateSessionUser(token, userId) {
      const session = data.sessions.find((item) => item.token === token);
      if (session) session.userId = userId;
      touch();
    },

    async deleteSession(token) {
      const index = data.sessions.findIndex((item) => item.token === token);
      if (index >= 0) data.sessions.splice(index, 1);
      touch();
    },

    async insertRecord(record) {
      data.records.push(structuredClone(record));
      touch();
    },

    async listRecords() {
      return data.records.map((record) => structuredClone(record));
    },

    async reassignUserData(fromUserId, toUserId) {
      for (const identity of data.identities) {
        if (identity.userId === fromUserId) identity.userId = toUserId;
      }
      for (const record of data.records) {
        if (record.userId === fromUserId) record.userId = toUserId;
      }
      for (const session of data.sessions) {
        if (session.userId === fromUserId) session.userId = toUserId;
      }
      touch();
    },

    async findPhoneCode(phone) {
      const row = data.phoneCodes.find((item) => item.phone === phone);
      return row ? structuredClone(row) : null;
    },

    async savePhoneCode(record) {
      const index = data.phoneCodes.findIndex((item) => item.phone === record.phone);
      const copy = structuredClone(record);
      if (index >= 0) data.phoneCodes[index] = copy;
      else data.phoneCodes.push(copy);
      touch();
    },

    async setPhoneCodeAttempts(phone, attempts) {
      const row = data.phoneCodes.find((item) => item.phone === phone);
      if (row) row.attempts = attempts;
      touch();
    },

    async deletePhoneCode(phone) {
      const index = data.phoneCodes.findIndex((item) => item.phone === phone);
      if (index >= 0) data.phoneCodes.splice(index, 1);
      touch();
    },
  };

  return repo;
}

function byCreated(left: { createdAt: string; id: string }, right: { createdAt: string; id: string }): number {
  if (left.createdAt === right.createdAt) return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
  return left.createdAt < right.createdAt ? -1 : 1;
}
