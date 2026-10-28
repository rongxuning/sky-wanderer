/**
 * Account identity model.
 *
 * A user can hold several identities (phone, WeChat, Google). Logging in with
 * an identity that already exists returns that user. Binding an identity that
 * belongs to a different user merges into the earlier-created account.
 *
 * Production checks live in the SMS, WeChat, and Google adapters. `DEMO_CODE`
 * is accepted only when the process is started with AUTH_DEMO=1.
 */

export const DEMO_CODE = "SKY-LOCAL";

export type IdentityType = "phone" | "wechat" | "google";

export const IDENTITY_TYPES: readonly IdentityType[] = ["phone", "wechat", "google"];

export interface User {
  id: string;
  createdAt: string;
  displayName: string;
  /** Profile email. Blank when the account has not collected one. */
  email: string;
  retiredAt: string | null;
  mergedIntoUserId: string | null;
  mergedFromUserIds: string[];
}

export interface Identity {
  id: string;
  type: IdentityType;
  /** E.164 phone, WeChat openid, or Google `sub`. */
  providerSubject: string;
  email: string | null;
  phone: string | null;
  userId: string;
  createdAt: string;
}

export interface Session {
  token: string;
  userId: string;
  createdAt: string;
}

/** Account-owned data moved onto the surviving user during a merge. */
export interface OwnedRecord {
  id: string;
  userId: string;
  kind: string;
  payload: Record<string, unknown>;
}

export interface AuthStore {
  users: User[];
  identities: Identity[];
  sessions: Session[];
  records: OwnedRecord[];
}

export function emptyStore(): AuthStore {
  return { users: [], identities: [], sessions: [], records: [] };
}

export class AuthError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "AuthError";
    this.code = code;
  }
}

export function isIdentityType(value: unknown): value is IdentityType {
  return typeof value === "string" && (IDENTITY_TYPES as readonly string[]).includes(value);
}

export function isConflict(error: unknown): boolean {
  return error instanceof AuthError && error.code === "identity_conflict";
}

export function canonicalSubject(type: IdentityType, raw: string): string {
  const trimmed = raw.trim();
  if (type !== "phone") {
    if (!trimmed) throw new AuthError("invalid_subject", "provider subject is required");
    return trimmed;
  }

  const compact = trimmed.replace(/[\s().-]/g, "");
  if (compact.startsWith("+")) {
    const digits = compact.slice(1).replace(/\D/g, "");
    if (digits.length < 8 || digits.length > 15) {
      throw new AuthError("invalid_phone", "phone must be an E.164 number");
    }
    return `+${digits}`;
  }

  const digits = compact.replace(/\D/g, "");
  if (/^1\d{10}$/.test(digits)) return `+86${digits}`;
  if (digits.startsWith("86") && digits.length === 13) return `+${digits}`;
  if (digits.length >= 8 && digits.length <= 15) return `+${digits}`;
  throw new AuthError("invalid_phone", "phone must be an E.164 number");
}

export function normalizeEmail(email: string | undefined): string {
  return email?.trim().toLowerCase() ?? "";
}
