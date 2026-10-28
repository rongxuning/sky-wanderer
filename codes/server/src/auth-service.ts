import { randomInt, randomUUID, type JsonWebKey } from "node:crypto";
import {
  DEMO_CODE,
  type Identity,
  type IdentityType,
  type Session,
  type User,
  AuthError,
  canonicalSubject,
  isConflict,
  normalizeEmail,
} from "./domain.ts";
import { codeHash, hashEqual } from "./hash.ts";
import { createGoogleChecker, exchangeWeChat, type GoogleCheckInput } from "./oauth.ts";
import type { AuthRepository } from "./repository.ts";
import type { FetchLike, SmsSender } from "./sms.ts";

export { DEMO_CODE, AuthError, canonicalSubject };
export type { Identity, IdentityType, Session, User };

export interface LoginInput {
  type: IdentityType;
  providerSubject?: string;
  demoCode?: string;
  smsCode?: string;
  authorizationCode?: string;
  idToken?: string;
  codeVerifier?: string;
  redirectUri?: string;
  clientId?: string;
  nonce?: string;
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

export interface PhoneCodeResult {
  phone: string;
  expiresInSeconds: number;
  demoCode?: string;
}

export interface AuthService {
  sendPhoneCode(phone: string): Promise<PhoneCodeResult>;
  loginOrRegister(input: LoginInput): Promise<LoginResult>;
  bindIdentity(input: BindInput): Promise<BindResult>;
  listIdentities(sessionToken: string): Promise<Identity[]>;
  unbindIdentity(input: UnbindInput): Promise<void>;
  logout(sessionToken: string): Promise<void>;
}

export interface AuthServiceOptions {
  repo: AuthRepository;
  now?: () => Date;
  newId?: () => string;
  demo?: boolean;
  sms?: SmsSender | null;
  fetch?: FetchLike;
  codePepper?: string;
  sessionTtlMs?: number;
  codeTtlMs?: number;
  resendAfterMs?: number;
  maxAttempts?: number;
  randomCode?: () => string;
  wechat?: { appId: string; appSecret: string } | null;
  googleClientIds?: string[];
  googleClientSecret?: string;
  googleRedirectUris?: string[];
  loadGoogleCerts?: () => Promise<Array<{ kid: string; jwk: JsonWebKey }>>;
}

interface Prepared {
  type: IdentityType;
  subject: string;
  email?: string;
  displayName?: string;
  phone?: string;
  smsCode?: string;
  demoBypass: boolean;
}

export function createAuthService(options: AuthServiceOptions): AuthService {
  const repo = options.repo;
  const now = options.now ?? (() => new Date());
  const newId = options.newId ?? (() => randomUUID());
  const demo = options.demo ?? false;
  const sms = options.sms ?? null;
  const fetchImpl = options.fetch ?? fetch;
  const pepper = options.codePepper ?? "";
  const sessionTtlMs = options.sessionTtlMs ?? 30 * 24 * 60 * 60 * 1000;
  const codeTtlMs = options.codeTtlMs ?? 5 * 60 * 1000;
  const resendAfterMs = options.resendAfterMs ?? 60 * 1000;
  const maxAttempts = options.maxAttempts ?? 5;
  const randomCode = options.randomCode ?? (() => randomInt(0, 1_000_000).toString().padStart(6, "0"));
  const wechat = options.wechat ?? null;
  const checkGoogle = createGoogleChecker({
    clientIds: options.googleClientIds ?? [],
    clientSecret: options.googleClientSecret ?? "",
    redirectUris: options.googleRedirectUris ?? [],
    fetchImpl,
    now,
    loadCerts: options.loadGoogleCerts,
  });

  function stamp(): string {
    return now().toISOString();
  }

  async function requireSession(store: AuthRepository, token: string): Promise<Session> {
    const found = await store.findSession(token);
    if (!found || Date.parse(found.expiresAt) <= now().getTime()) {
      throw new AuthError("not_authenticated", "session is missing or expired");
    }
    return { token, userId: found.userId, createdAt: found.createdAt };
  }

  async function activeUser(store: AuthRepository, userId: string): Promise<User> {
    const seen = new Set<string>();
    let currentId = userId;
    while (true) {
      const user = await store.findUser(currentId);
      if (!user) throw new AuthError("user_missing", "account does not exist");
      if (!user.retiredAt) return user;
      if (!user.mergedIntoUserId || seen.has(user.id)) {
        throw new AuthError("user_missing", "account does not exist");
      }
      seen.add(user.id);
      currentId = user.mergedIntoUserId;
    }
  }

  async function openSession(store: AuthRepository, userId: string): Promise<Session> {
    const createdAt = stamp();
    const session: Session = { token: newId(), userId, createdAt };
    await store.insertSession({
      token: session.token,
      userId,
      createdAt,
      expiresAt: new Date(now().getTime() + sessionTtlMs).toISOString(),
    });
    return session;
  }

  async function prepare(input: LoginInput): Promise<Prepared> {
    if (input.type === "phone") {
      const subject = canonicalSubject("phone", input.providerSubject ?? "");
      const smsCode = (input.smsCode ?? input.demoCode ?? "").trim();
      return {
        type: "phone",
        subject,
        email: input.email,
        displayName: input.displayName,
        phone: subject,
        smsCode,
        demoBypass: demo && smsCode === DEMO_CODE,
      };
    }

    if (input.type === "wechat") {
      const code = input.authorizationCode?.trim();
      if (code) {
        const profile = await exchangeWeChat({
          appId: wechat?.appId ?? "",
          appSecret: wechat?.appSecret ?? "",
          code,
          fetchImpl,
        });
        return {
          type: "wechat",
          subject: canonicalSubject("wechat", profile.subject),
          displayName: profile.displayName,
          demoBypass: false,
        };
      }
      if (demo && input.providerSubject?.trim()) {
        return {
          type: "wechat",
          subject: canonicalSubject("wechat", input.providerSubject),
          displayName: input.displayName,
          email: input.email,
          phone: input.phone,
          demoBypass: false,
        };
      }
      throw new AuthError(
        "invalid_subject",
        demo ? "provider subject is required" : "WeChat login requires an authorization code",
      );
    }

    const googleInput: GoogleCheckInput = {
      idToken: input.idToken,
      authorizationCode: input.authorizationCode,
      codeVerifier: input.codeVerifier,
      redirectUri: input.redirectUri,
      clientId: input.clientId,
      nonce: input.nonce,
    };
    if (googleInput.idToken?.trim() || googleInput.authorizationCode?.trim()) {
      const profile = await checkGoogle(googleInput);
      return {
        type: "google",
        subject: canonicalSubject("google", profile.subject),
        email: profile.email,
        displayName: profile.displayName,
        demoBypass: false,
      };
    }
    if (demo && input.providerSubject?.trim()) {
      return {
        type: "google",
        subject: canonicalSubject("google", input.providerSubject),
        displayName: input.displayName,
        email: input.email,
        phone: input.phone,
        demoBypass: false,
      };
    }
    throw new AuthError("invalid_subject", demo ? "provider subject is required" : "Google login requires an ID token");
  }

  async function consumeCode(store: AuthRepository, phone: string, code: string): Promise<void> {
    const hashed = codeHash(pepper, code);
    const row = await store.findPhoneCode(phone);
    if (!row) {
      throw new AuthError(
        demo ? "invalid_demo_code" : "invalid_sms_code",
        demo ? "phone demo code must be SKY-LOCAL" : "SMS code is incorrect",
      );
    }
    if (Date.parse(row.expiresAt) <= now().getTime()) {
      await store.deletePhoneCode(phone);
      throw new AuthError("sms_expired", "SMS code has expired");
    }
    if (row.attempts >= maxAttempts || !hashEqual(row.codeHash, hashed)) {
      const attempts = row.attempts + (hashEqual(row.codeHash, hashed) ? 0 : 1);
      if (attempts >= maxAttempts) await store.deletePhoneCode(phone);
      else await store.setPhoneCodeAttempts(phone, attempts);
      throw new AuthError("invalid_sms_code", "SMS code is incorrect");
    }
    await store.deletePhoneCode(phone);
  }

  function displayNameFor(prepared: Prepared, email: string): string {
    const given = prepared.displayName?.trim();
    if (given) return given;
    if (prepared.type === "wechat") return "微信用户";
    if (prepared.type === "google") {
      const local = email.split("@")[0];
      return local || "Google 用户";
    }
    return `手机 ${prepared.subject.slice(-4)}`;
  }

  async function insertOrLoad(store: AuthRepository, prepared: Prepared): Promise<LoginResult> {
    const existing = await store.findIdentity(prepared.type, prepared.subject);
    if (existing) {
      const user = await activeUser(store, existing.userId);
      if (existing.userId !== user.id) await store.updateIdentityUser(existing.id, user.id);
      const session = await openSession(store, user.id);
      return { user, session, created: false };
    }

    const createdAt = stamp();
    const email = normalizeEmail(prepared.email);
    const user: User = {
      id: newId(),
      createdAt,
      displayName: displayNameFor(prepared, email),
      email,
      retiredAt: null,
      mergedIntoUserId: null,
      mergedFromUserIds: [],
    };
    const identity: Identity = {
      id: newId(),
      type: prepared.type,
      providerSubject: prepared.subject,
      email: email || null,
      phone: prepared.type === "phone" ? prepared.subject : prepared.phone?.trim() || null,
      userId: user.id,
      createdAt,
    };
    await store.insertUser(user);
    await store.insertIdentity(identity);
    const session = await openSession(store, user.id);
    return { user, session, created: true };
  }

  async function mergeUsers(store: AuthRepository, leftId: string, rightId: string): Promise<User> {
    const left = await activeUser(store, leftId);
    const right = await activeUser(store, rightId);
    if (left.id === right.id) return left;

    const leftTime = Date.parse(left.createdAt);
    const rightTime = Date.parse(right.createdAt);
    const rightIsEarlier = rightTime < leftTime || (rightTime === leftTime && right.id < left.id);
    const master = rightIsEarlier ? right : left;
    const loser = rightIsEarlier ? left : right;

    await store.reassignUserData(loser.id, master.id);
    if (!master.displayName.trim() && loser.displayName.trim()) master.displayName = loser.displayName;
    if (!master.email.trim() && loser.email.trim()) master.email = loser.email;
    master.mergedFromUserIds = [...master.mergedFromUserIds, loser.id, ...loser.mergedFromUserIds];
    loser.retiredAt = stamp();
    loser.mergedIntoUserId = master.id;
    await store.updateUser(master);
    await store.updateUser(loser);
    return master;
  }

  async function bindPrepared(
    store: AuthRepository,
    token: string,
    current: User,
    prepared: Prepared,
  ): Promise<BindResult> {
    const existing = await store.findIdentity(prepared.type, prepared.subject);
    if (existing) {
      const owner = await activeUser(store, existing.userId);
      if (existing.userId !== owner.id) await store.updateIdentityUser(existing.id, owner.id);
      if (owner.id === current.id) {
        const session = await requireSession(store, token);
        if (session.userId !== current.id) {
          await store.updateSessionUser(token, current.id);
          session.userId = current.id;
        }
        return { user: current, session, merged: false };
      }
      const master = await mergeUsers(store, current.id, owner.id);
      const live = await requireSession(store, token);
      return { user: master, session: live, merged: true };
    }

    const email = normalizeEmail(prepared.email);
    await store.insertIdentity({
      id: newId(),
      type: prepared.type,
      providerSubject: prepared.subject,
      email: email || null,
      phone: prepared.type === "phone" ? prepared.subject : prepared.phone?.trim() || null,
      userId: current.id,
      createdAt: stamp(),
    });
    if (email && !current.email.trim()) {
      current.email = email;
      await store.updateUser(current);
    }
    const session = await requireSession(store, token);
    return { user: current, session, merged: false };
  }

  async function withCode(store: AuthRepository, prepared: Prepared): Promise<void> {
    if (prepared.type === "phone" && !prepared.demoBypass) {
      await consumeCode(store, prepared.subject, prepared.smsCode ?? "");
    }
  }

  async function run<T>(work: (store: AuthRepository) => Promise<T>): Promise<T> {
    try {
      return await repo.transaction(work);
    } catch (error) {
      if (!isConflict(error)) throw error;
      return repo.transaction(work);
    }
  }

  return {
    async sendPhoneCode(phone) {
      const subject = canonicalSubject("phone", phone);
      if (!sms) {
        if (demo) {
          return { phone: subject, expiresInSeconds: Math.round(codeTtlMs / 1000), demoCode: DEMO_CODE };
        }
        throw new AuthError(
          "sms_not_configured",
          "SMS is not configured. Set SMS_PROVIDER and its credentials.",
        );
      }
      const existing = await repo.transaction((tx) => tx.findPhoneCode(subject));
      if (existing && Date.parse(existing.sentAt) + resendAfterMs > now().getTime()) {
        throw new AuthError("sms_rate_limited", "Wait before requesting another SMS code");
      }
      const code = randomCode();
      await sms.send(subject, code);
      const sentAt = stamp();
      await repo.transaction((tx) =>
        tx.savePhoneCode({
          phone: subject,
          codeHash: codeHash(pepper, code),
          expiresAt: new Date(now().getTime() + codeTtlMs).toISOString(),
          attempts: 0,
          sentAt,
        }),
      );
      return { phone: subject, expiresInSeconds: Math.round(codeTtlMs / 1000) };
    },

    async loginOrRegister(input) {
      const prepared = await prepare(input);
      return run(async (tx) => {
        await withCode(tx, prepared);
        return insertOrLoad(tx, prepared);
      });
    },

    async bindIdentity(input) {
      const prepared = await prepare(input);
      return run(async (tx) => {
        const session = await requireSession(tx, input.sessionToken);
        const current = await activeUser(tx, session.userId);
        await withCode(tx, prepared);
        return bindPrepared(tx, input.sessionToken, current, prepared);
      });
    },

    async listIdentities(sessionToken) {
      return repo.transaction(async (tx) => {
        const session = await requireSession(tx, sessionToken);
        const user = await activeUser(tx, session.userId);
        return tx.listIdentitiesByUser(user.id);
      });
    },

    async unbindIdentity(input) {
      await repo.transaction(async (tx) => {
        const session = await requireSession(tx, input.sessionToken);
        const user = await activeUser(tx, session.userId);
        const subject = canonicalSubject(input.type, input.providerSubject);
        const owned = await tx.listIdentitiesByUser(user.id);
        const target = owned.find((item) => item.type === input.type && item.providerSubject === subject);
        if (!target) throw new AuthError("identity_not_found", "identity is not on this account");
        if (owned.length <= 1) {
          throw new AuthError("last_identity", "at least one identity must remain on the account");
        }
        await tx.deleteIdentity(target.id);
      });
    },

    async logout(sessionToken) {
      await repo.deleteSession(sessionToken);
    },
  };
}
