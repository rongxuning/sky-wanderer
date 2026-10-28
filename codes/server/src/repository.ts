import type { Identity, IdentityType, OwnedRecord, User } from "./domain.ts";

export interface StoredSession {
  userId: string;
  createdAt: string;
  expiresAt: string;
}

export interface PhoneCodeRecord {
  phone: string;
  codeHash: string;
  expiresAt: string;
  attempts: number;
  sentAt: string;
}

export interface NewSession {
  token: string;
  userId: string;
  createdAt: string;
  expiresAt: string;
}

/**
 * Persistence port for accounts. Postgres is the production store.
 * AUTH_DEMO=1 without DATABASE_URL uses the in-memory store.
 * `transaction` runs `fn` on a handle bound to that transaction.
 */
export interface AuthRepository {
  transaction<T>(fn: (tx: AuthRepository) => Promise<T>): Promise<T>;
  ping(): Promise<void>;
  findUser(id: string): Promise<User | null>;
  insertUser(user: User): Promise<void>;
  updateUser(user: User): Promise<void>;
  listUsers(): Promise<User[]>;
  findIdentity(type: IdentityType, providerSubject: string): Promise<Identity | null>;
  insertIdentity(identity: Identity): Promise<void>;
  updateIdentityUser(id: string, userId: string): Promise<void>;
  listIdentitiesByUser(userId: string): Promise<Identity[]>;
  listIdentities(): Promise<Identity[]>;
  deleteIdentity(id: string): Promise<void>;
  insertSession(session: NewSession): Promise<void>;
  findSession(token: string): Promise<StoredSession | null>;
  updateSessionUser(token: string, userId: string): Promise<void>;
  deleteSession(token: string): Promise<void>;
  insertRecord(record: OwnedRecord): Promise<void>;
  listRecords(): Promise<OwnedRecord[]>;
  reassignUserData(fromUserId: string, toUserId: string): Promise<void>;
  findPhoneCode(phone: string): Promise<PhoneCodeRecord | null>;
  savePhoneCode(record: PhoneCodeRecord): Promise<void>;
  setPhoneCodeAttempts(phone: string, attempts: number): Promise<void>;
  deletePhoneCode(phone: string): Promise<void>;
}
