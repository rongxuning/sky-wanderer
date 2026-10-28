import { createPublicKey, verify as verifySignature, type JsonWebKey } from "node:crypto";
import { AuthError } from "./domain.ts";
import type { FetchLike } from "./sms.ts";

export interface OAuthProfile {
  subject: string;
  email?: string;
  displayName?: string;
}

const GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";

export async function exchangeWeChat(options: {
  appId: string;
  appSecret: string;
  code: string;
  fetchImpl: FetchLike;
}): Promise<OAuthProfile> {
  if (!options.appId || !options.appSecret) {
    throw new AuthError("wechat_not_configured", "Set both WECHAT_APP_ID and WECHAT_APP_SECRET");
  }
  const url = new URL("https://api.weixin.qq.com/sns/oauth2/access_token");
  url.searchParams.set("appid", options.appId);
  url.searchParams.set("secret", options.appSecret);
  url.searchParams.set("code", options.code);
  url.searchParams.set("grant_type", "authorization_code");
  const response = await options.fetchImpl(url, { redirect: "error" });
  const body = (await response.json().catch(() => ({}))) as {
    openid?: string;
    access_token?: string;
    errcode?: number;
    errmsg?: string;
  };
  if (!response.ok || body.errcode || !body.openid) {
    throw new AuthError("wechat_exchange_failed", "WeChat did not return an openid for this authorization code");
  }
  let displayName: string | undefined;
  if (body.access_token) {
    displayName = await wechatNickname(body.access_token, body.openid, options.fetchImpl);
  }
  return { subject: body.openid, displayName };
}

async function wechatNickname(accessToken: string, openid: string, fetchImpl: FetchLike): Promise<string | undefined> {
  try {
    const url = new URL("https://api.weixin.qq.com/sns/userinfo");
    url.searchParams.set("access_token", accessToken);
    url.searchParams.set("openid", openid);
    url.searchParams.set("lang", "zh_CN");
    const response = await fetchImpl(url, { redirect: "error" });
    const body = (await response.json().catch(() => ({}))) as { nickname?: string; errcode?: number };
    if (!response.ok || body.errcode || !body.nickname?.trim()) return undefined;
    return body.nickname.trim();
  } catch {
    return undefined;
  }
}

export interface GoogleCheckInput {
  idToken?: string;
  authorizationCode?: string;
  codeVerifier?: string;
  redirectUri?: string;
  clientId?: string;
  nonce?: string;
}

export interface GoogleCheckerOptions {
  clientIds: string[];
  clientSecret: string;
  redirectUris: string[];
  fetchImpl: FetchLike;
  now: () => Date;
  loadCerts?: () => Promise<Array<{ kid: string; jwk: JsonWebKey }>>;
}

export function createGoogleChecker(options: GoogleCheckerOptions): (input: GoogleCheckInput) => Promise<OAuthProfile> {
  let cache: { at: number; byKid: Map<string, JsonWebKey> } | null = null;

  async function certs(): Promise<Map<string, JsonWebKey>> {
    const nowMs = options.now().getTime();
    if (cache && nowMs - cache.at < 60 * 60 * 1000) return cache.byKid;
    const loaded = options.loadCerts ? await options.loadCerts() : await fetchGoogleCerts(options.fetchImpl);
    const byKid = new Map<string, JsonWebKey>();
    for (const item of loaded) {
      if (item.kid) byKid.set(item.kid, item.jwk);
    }
    cache = { at: nowMs, byKid };
    return byKid;
  }

  return async function check(input) {
    if (options.clientIds.length === 0) {
      throw new AuthError("google_not_configured", "Set GOOGLE_CLIENT_IDS to the allowed Google client ids");
    }
    let idToken = input.idToken?.trim() ?? "";
    if (!idToken && input.authorizationCode?.trim()) {
      idToken = await exchangeGoogleCode(options, input);
    }
    if (!idToken) throw new AuthError("invalid_id_token", "Google ID token is missing");
    const claims = await verifyGoogleIdToken(idToken, await certs(), options.clientIds, options.now().getTime());
    if (input.nonce && claims.nonce !== input.nonce) {
      throw new AuthError("invalid_id_token", "Google ID token nonce does not match");
    }
    return { subject: claims.sub, email: claims.email, displayName: claims.name };
  };
}

async function exchangeGoogleCode(options: GoogleCheckerOptions, input: GoogleCheckInput): Promise<string> {
  const code = input.authorizationCode?.trim() ?? "";
  const redirectUri = input.redirectUri?.trim() ?? "";
  const clientId = input.clientId?.trim() || (options.clientIds.length === 1 ? options.clientIds[0] : "");
  const verifier = input.codeVerifier?.trim() ?? "";
  if (!clientId || !options.clientIds.includes(clientId)) {
    throw new AuthError("google_not_configured", "Google client id is not in GOOGLE_CLIENT_IDS");
  }
  if (!redirectUri || !options.redirectUris.includes(redirectUri)) {
    throw new AuthError("invalid_subject", "Google redirect URI is not allowed");
  }
  if (!options.clientSecret && !verifier) {
    throw new AuthError(
      "google_not_configured",
      "Set GOOGLE_CLIENT_SECRET for the web client, or send a PKCE code verifier",
    );
  }
  const body = new URLSearchParams({
    code,
    client_id: clientId,
    redirect_uri: redirectUri,
    grant_type: "authorization_code",
  });
  if (options.clientSecret) body.set("client_secret", options.clientSecret);
  if (verifier) body.set("code_verifier", verifier);
  const response = await options.fetchImpl(GOOGLE_TOKEN_URL, {
    method: "POST",
    redirect: "error",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const payload = (await response.json().catch(() => ({}))) as { id_token?: string };
  if (!response.ok || !payload.id_token) {
    throw new AuthError("invalid_id_token", "Google did not return an ID token for this authorization code");
  }
  return payload.id_token;
}

async function fetchGoogleCerts(fetchImpl: FetchLike): Promise<Array<{ kid: string; jwk: JsonWebKey }>> {
  const response = await fetchImpl(GOOGLE_CERTS_URL, { redirect: "error" });
  if (!response.ok) throw new AuthError("invalid_id_token", "Could not load Google signing keys");
  const body = (await response.json()) as { keys?: Array<JsonWebKey & { kid?: string }> };
  return (body.keys ?? [])
    .filter((key) => key.kid)
    .map((key) => ({ kid: key.kid as string, jwk: key }));
}

interface GoogleClaims {
  sub: string;
  email?: string;
  name?: string;
  nonce?: string;
}

export async function verifyGoogleIdToken(
  token: string,
  certs: Map<string, JsonWebKey>,
  clientIds: string[],
  nowMs: number,
): Promise<GoogleClaims> {
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[0] || !parts[1] || !parts[2]) {
    throw new AuthError("invalid_id_token", "Google ID token is malformed");
  }
  let header: { alg?: string; kid?: string };
  try {
    header = JSON.parse(decodeBase64Url(parts[0]).toString("utf8")) as { alg?: string; kid?: string };
  } catch {
    throw new AuthError("invalid_id_token", "Google ID token is malformed");
  }
  if (header.alg !== "RS256" || !header.kid) {
    throw new AuthError("invalid_id_token", "Google ID token algorithm is not RS256");
  }
  const jwk = certs.get(header.kid);
  if (!jwk) throw new AuthError("invalid_id_token", "Google signing key was not found");
  let valid = false;
  try {
    const key = createPublicKey({ key: jwk, format: "jwk" });
    valid = verifySignature("RSA-SHA256", Buffer.from(`${parts[0]}.${parts[1]}`), key, decodeBase64Url(parts[2]));
  } catch {
    valid = false;
  }
  if (!valid) throw new AuthError("invalid_id_token", "Google ID token signature is invalid");

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(decodeBase64Url(parts[1]).toString("utf8")) as Record<string, unknown>;
  } catch {
    throw new AuthError("invalid_id_token", "Google ID token is malformed");
  }
  const iss = payload.iss;
  if (iss !== "https://accounts.google.com" && iss !== "accounts.google.com") {
    throw new AuthError("invalid_id_token", "Google ID token issuer is not Google");
  }
  const audiences = Array.isArray(payload.aud) ? payload.aud : payload.aud != null ? [payload.aud] : [];
  if (!audiences.some((item) => typeof item === "string" && clientIds.includes(item))) {
    throw new AuthError("invalid_id_token", "Google ID token audience does not match");
  }
  if (typeof payload.exp !== "number" || payload.exp * 1000 <= nowMs - 60_000) {
    throw new AuthError("invalid_id_token", "Google ID token has expired");
  }
  if (typeof payload.nbf === "number" && payload.nbf * 1000 > nowMs + 60_000) {
    throw new AuthError("invalid_id_token", "Google ID token is not valid yet");
  }
  if (typeof payload.sub !== "string" || !payload.sub) {
    throw new AuthError("invalid_id_token", "Google ID token is missing sub");
  }
  const emailVerified = payload.email_verified === true || payload.email_verified === "true";
  const email = emailVerified && typeof payload.email === "string" ? payload.email : undefined;
  const name = typeof payload.name === "string" && payload.name.trim() ? payload.name.trim() : undefined;
  const nonce = typeof payload.nonce === "string" ? payload.nonce : undefined;
  return { sub: payload.sub, email, name, nonce };
}

function decodeBase64Url(input: string): Buffer {
  const padded = input.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (input.length % 4)) % 4);
  return Buffer.from(padded, "base64");
}
