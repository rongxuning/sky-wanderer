import { randomUUID } from "node:crypto";
import {
  type AuthStore,
  type Identity,
  type IdentityType,
  type Session,
  type User,
  AuthError,
  canonicalSubject,
  emptyStore,
  normalizeEmail,
  verifyStub,
  DEMO_CODE,
} from "./domain.ts";

export { DEMO_CODE, emptyStore, AuthError, canonicalSubject };
export type { AuthStore, Identity, IdentityType, OwnedRecord, Session, User } from "./domain.ts";

export interface LoginInput {
  type: IdentityType;
  providerSubject: string;
  demoCode?: string;
  displayName?: string;
  email?: string;
  phone?: string;
}

export interface LoginResult {
  user: User;
  session: Session;
  created: boolean;
}

export interface BindInput extends LoginInput {
  sessionToken: string;
}

export interface BindResult {
  user: User;
  session: Session;
  merged: boolean;
}

export interface UnbindInput {
  sessionToken: string;
  type: IdentityType;
  providerSubject: string;
}

export interface AuthService {
  loginOrRegister(input: LoginInput): LoginResult;
  bindIdentity(input: BindInput): BindResult;
  listIdentities(sessionToken: string): Identity[];
  unbindIdentity(input: UnbindInput): void;
  logout(sessionToken: string): void;
}

export interface AuthServiceOptions {
  now?: () => Date;
  newId?: () => string;
  onChange?: () => void;
}

export function createAuthService(store: AuthStore = emptyStore(), options: AuthServiceOptions = {}): AuthService {
  const now = options.now ?? (() => new Date());
  const newId = options.newId ?? (() => randomUUID());

  function touch() {
    options.onChange?.();
  }

  function stamp(): string {
    return now().toISOString();
  }

  function requireSession(token: string): Session {
    const session = store.sessions.find((item) => item.token === token);
    if (!session) throw new AuthError("not_authenticated", "session is missing or expired");
    return session;
  }

  function activeUser(userId: string): User {
    const seen = new Set<string>();
    let currentId = userId;
    while (true) {
      const user = store.users.find((item) => item.id === currentId);
      if (!user) throw new AuthError("user_missing", "account does not exist");
      if (!user.retiredAt) return user;
      if (!user.mergedIntoUserId || seen.has(user.id)) {
        throw new AuthError("user_missing", "account does not exist");
      }
      seen.add(user.id);
      currentId = user.mergedIntoUserId;
    }
  }

  function openSession(userId: string): Session {
    const session: Session = { token: newId(), userId, createdAt: stamp() };
    store.sessions.push(session);
    return session;
  }

  function identityFor(type: IdentityType, providerSubject: string): Identity | undefined {
    const subject = canonicalSubject(type, providerSubject);
    return store.identities.find((item) => item.type === type && item.providerSubject === subject);
  }

  function displayNameFor(input: LoginInput, subject: string): string {
    const given = input.displayName?.trim();
    if (given) return given;
    if (input.type === "wechat") return "微信用户";
    if (input.type === "google") {
      const email = normalizeEmail(input.email);
      const local = email.split("@")[0];
      return local || "Google 用户";
    }
    return `手机 ${subject.slice(-4)}`;
  }

  function mergeUsers(leftId: string, rightId: string): User {
    const left = activeUser(leftId);
    const right = activeUser(rightId);
    if (left.id === right.id) return left;

    const leftTime = Date.parse(left.createdAt);
    const rightTime = Date.parse(right.createdAt);
    const rightIsEarlier =
      rightTime < leftTime || (rightTime === leftTime && right.id < left.id);
    const master = rightIsEarlier ? right : left;
    const loser = rightIsEarlier ? left : right;

    for (const identity of store.identities) {
      if (identity.userId === loser.id) identity.userId = master.id;
    }
    for (const record of store.records) {
      if (record.userId === loser.id) record.userId = master.id;
    }
    for (const session of store.sessions) {
      if (session.userId === loser.id) session.userId = master.id;
    }
    if (!master.displayName.trim() && loser.displayName.trim()) master.displayName = loser.displayName;
    if (!master.email.trim() && loser.email.trim()) master.email = loser.email;
    master.mergedFromUserIds = [...master.mergedFromUserIds, loser.id, ...loser.mergedFromUserIds];
    loser.retiredAt = stamp();
    loser.mergedIntoUserId = master.id;
    return master;
  }

  return {
    loginOrRegister(input) {
      verifyStub(input.type, input.demoCode);
      const subject = canonicalSubject(input.type, input.providerSubject);
      const existing = identityFor(input.type, subject);
      if (existing) {
        const user = activeUser(existing.userId);
        if (existing.userId !== user.id) existing.userId = user.id;
        const session = openSession(user.id);
        touch();
        return { user: structuredClone(user), session: structuredClone(session), created: false };
      }

      const createdAt = stamp();
      const email = normalizeEmail(input.email);
      const user: User = {
        id: newId(),
        createdAt,
        displayName: displayNameFor(input, subject),
        email,
        retiredAt: null,
        mergedIntoUserId: null,
        mergedFromUserIds: [],
      };
      const identity: Identity = {
        id: newId(),
        type: input.type,
        providerSubject: subject,
        email: email || null,
        phone: input.type === "phone" ? subject : input.phone?.trim() || null,
        userId: user.id,
        createdAt,
      };
      store.users.push(user);
      store.identities.push(identity);
      const session = openSession(user.id);
      touch();
      return { user: structuredClone(user), session: structuredClone(session), created: true };
    },

    bindIdentity(input) {
      const session = requireSession(input.sessionToken);
      const current = activeUser(session.userId);
      verifyStub(input.type, input.demoCode);
      const subject = canonicalSubject(input.type, input.providerSubject);
      const existing = identityFor(input.type, subject);

      if (existing) {
        const owner = activeUser(existing.userId);
        if (existing.userId !== owner.id) existing.userId = owner.id;
        if (owner.id === current.id) {
          if (session.userId !== current.id) session.userId = current.id;
          touch();
          return {
            user: structuredClone(current),
            session: structuredClone(session),
            merged: false,
          };
        }
        const master = mergeUsers(current.id, owner.id);
        const live = requireSession(input.sessionToken);
        touch();
        return { user: structuredClone(master), session: structuredClone(live), merged: true };
      }

      const email = normalizeEmail(input.email);
      store.identities.push({
        id: newId(),
        type: input.type,
        providerSubject: subject,
        email: email || null,
        phone: input.type === "phone" ? subject : input.phone?.trim() || null,
        userId: current.id,
        createdAt: stamp(),
      });
      if (email && !current.email.trim()) current.email = email;
      touch();
      return { user: structuredClone(current), session: structuredClone(session), merged: false };
    },

    listIdentities(sessionToken) {
      const session = requireSession(sessionToken);
      const user = activeUser(session.userId);
      return store.identities.filter((item) => item.userId === user.id).map((item) => structuredClone(item));
    },

    unbindIdentity(input) {
      const session = requireSession(input.sessionToken);
      const user = activeUser(session.userId);
      const subject = canonicalSubject(input.type, input.providerSubject);
      const owned = store.identities.filter((item) => item.userId === user.id);
      const target = owned.find((item) => item.type === input.type && item.providerSubject === subject);
      if (!target) throw new AuthError("identity_not_found", "identity is not on this account");
      if (owned.length <= 1) {
        throw new AuthError("last_identity", "at least one identity must remain on the account");
      }
      const index = store.identities.findIndex((item) => item.id === target.id);
      if (index >= 0) store.identities.splice(index, 1);
      touch();
    },

    logout(sessionToken) {
      const index = store.sessions.findIndex((item) => item.token === sessionToken);
      if (index < 0) return;
      store.sessions.splice(index, 1);
      touch();
    },
  };
}
