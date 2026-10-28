import type { IncomingMessage, ServerResponse } from "node:http";
import { AuthError, isIdentityType, type IdentityType } from "./domain.ts";
import type { AuthService, LoginInput } from "./auth-service.ts";

interface AuthBody {
  type?: unknown;
  providerSubject?: unknown;
  demoCode?: unknown;
  smsCode?: unknown;
  authorizationCode?: unknown;
  idToken?: unknown;
  codeVerifier?: unknown;
  redirectUri?: unknown;
  clientId?: unknown;
  nonce?: unknown;
  displayName?: unknown;
  email?: unknown;
  phone?: unknown;
}

function statusFor(code: string): number {
  switch (code) {
    case "not_authenticated":
      return 401;
    case "last_identity":
      return 409;
    case "identity_not_found":
    case "user_missing":
      return 404;
    case "sms_rate_limited":
      return 429;
    case "sms_not_configured":
    case "wechat_not_configured":
    case "google_not_configured":
    case "db_unavailable":
      return 503;
    case "sms_failed":
      return 502;
    default:
      return 400;
  }
}

function send(res: ServerResponse, status: number, body: unknown): void {
  if (status === 204) {
    res.writeHead(204);
    res.end();
    return;
  }
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    "cache-control": "no-store",
  });
  res.end(payload);
}

function bearer(req: IncomingMessage): string | undefined {
  const header = req.headers.authorization;
  if (!header) return undefined;
  const [scheme, token] = header.split(" ");
  if (scheme?.toLowerCase() !== "bearer" || !token) return undefined;
  return token;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function readLogin(body: AuthBody): LoginInput {
  if (!isIdentityType(body.type)) {
    throw new AuthError("invalid_subject", "type must be phone, wechat, or google");
  }
  return {
    type: body.type,
    providerSubject: optionalString(body.providerSubject),
    demoCode: optionalString(body.demoCode),
    smsCode: optionalString(body.smsCode),
    authorizationCode: optionalString(body.authorizationCode),
    idToken: optionalString(body.idToken),
    codeVerifier: optionalString(body.codeVerifier),
    redirectUri: optionalString(body.redirectUri),
    clientId: optionalString(body.clientId),
    nonce: optionalString(body.nonce),
    displayName: optionalString(body.displayName),
    email: optionalString(body.email),
    phone: optionalString(body.phone),
  };
}

function readIdentity(body: AuthBody): { type: IdentityType; providerSubject: string } {
  const login = readLogin(body);
  if (!login.providerSubject) {
    throw new AuthError("invalid_subject", "providerSubject is required");
  }
  return { type: login.type, providerSubject: login.providerSubject };
}

async function readJson(req: IncomingMessage): Promise<AuthBody> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buffer = typeof chunk === "string" ? Buffer.from(chunk) : chunk;
    size += buffer.length;
    if (size > 32_768) throw new AuthError("invalid_subject", "body is too large");
    chunks.push(buffer);
  }
  if (chunks.length === 0) return {};
  try {
    const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new AuthError("invalid_subject", "body must be a JSON object");
    }
    return parsed as AuthBody;
  } catch (error) {
    if (error instanceof AuthError) throw error;
    throw new AuthError("invalid_subject", "body must be JSON");
  }
}

function redirectToApp(res: ServerResponse, route: "wechat" | "google", query: URLSearchParams): void {
  const target = new URL(`skywanderer://auth/${route}`);
  for (const [key, value] of query) {
    if (value) target.searchParams.set(key, value);
  }
  res.writeHead(302, { location: target.toString(), "cache-control": "no-store" });
  res.end();
}

function callbackQuery(url: URL): URLSearchParams {
  const code = url.searchParams.get("code") ?? "";
  const state = url.searchParams.get("state") ?? "";
  const providerError = url.searchParams.get("error") ?? "";
  const params = new URLSearchParams();
  if (code) params.set("code", code);
  if (state) params.set("state", state);
  if (providerError) params.set("error", providerError);
  else if (!code) params.set("error", "missing_code");
  return params;
}

export interface HttpOptions {
  ready?: () => Promise<void>;
}

export async function handleAuthRequest(
  auth: AuthService,
  req: IncomingMessage,
  res: ServerResponse,
  options: HttpOptions = {},
): Promise<void> {
  const url = new URL(req.url ?? "/", "http://localhost");
  const path = url.pathname.length > 1 && url.pathname.endsWith("/") ? url.pathname.slice(0, -1) : url.pathname;
  try {
    if (req.method === "GET" && path === "/health") {
      if (options.ready) await options.ready();
      send(res, 200, { ok: true });
      return;
    }

    if (req.method === "GET" && path === "/v1/auth/wechat/callback") {
      redirectToApp(res, "wechat", callbackQuery(url));
      return;
    }

    if (req.method === "GET" && path === "/v1/auth/google/callback") {
      redirectToApp(res, "google", callbackQuery(url));
      return;
    }

    if (req.method === "POST" && path === "/v1/auth/phone/send-code") {
      const body = await readJson(req);
      if (typeof body.phone !== "string") throw new AuthError("invalid_phone", "phone must be an E.164 number");
      send(res, 200, await auth.sendPhoneCode(body.phone));
      return;
    }

    if (req.method === "POST" && path === "/v1/auth/login") {
      const body = await readJson(req);
      const result = await auth.loginOrRegister(readLogin(body));
      send(res, 200, {
        user: result.user,
        session: result.session,
        created: result.created,
        merged: false,
        identities: await auth.listIdentities(result.session.token),
      });
      return;
    }

    const token = bearer(req);
    if (!token) throw new AuthError("not_authenticated", "session is missing or expired");

    if (req.method === "POST" && path === "/v1/auth/bind") {
      const body = await readJson(req);
      const result = await auth.bindIdentity({ sessionToken: token, ...readLogin(body) });
      send(res, 200, {
        user: result.user,
        session: result.session,
        created: false,
        merged: result.merged,
        identities: await auth.listIdentities(result.session.token),
      });
      return;
    }

    if (req.method === "GET" && path === "/v1/auth/identities") {
      send(res, 200, { identities: await auth.listIdentities(token) });
      return;
    }

    if (req.method === "DELETE" && path === "/v1/auth/identities") {
      const body = await readJson(req);
      const identity = readIdentity(body);
      await auth.unbindIdentity({ sessionToken: token, ...identity });
      send(res, 200, { identities: await auth.listIdentities(token) });
      return;
    }

    if (req.method === "POST" && path === "/v1/auth/logout") {
      await auth.logout(token);
      send(res, 204, {});
      return;
    }

    send(res, 404, { error: { code: "not_found", message: "not found" } });
  } catch (error) {
    if (error instanceof AuthError) {
      send(res, statusFor(error.code), { error: { code: error.code, message: error.message } });
      return;
    }
    console.error(error);
    send(res, 500, { error: { code: "internal", message: "internal error" } });
  }
}
