import type { IncomingMessage, ServerResponse } from "node:http";
import { AuthError, isIdentityType, type IdentityType } from "./domain.ts";
import type { AuthService } from "./auth-service.ts";

interface AuthBody {
  type?: unknown;
  providerSubject?: unknown;
  demoCode?: unknown;
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

function readIdentity(body: AuthBody): { type: IdentityType; providerSubject: string } {
  if (!isIdentityType(body.type)) {
    throw new AuthError("invalid_subject", "type must be phone, wechat, or google");
  }
  if (typeof body.providerSubject !== "string") {
    throw new AuthError("invalid_subject", "providerSubject is required");
  }
  return { type: body.type, providerSubject: body.providerSubject };
}

async function readJson(req: IncomingMessage): Promise<AuthBody> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
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

export async function handleAuthRequest(auth: AuthService, req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "/", "http://localhost");
  const path = url.pathname;
  try {
    if (req.method === "GET" && path === "/health") {
      send(res, 200, { ok: true });
      return;
    }

    if (req.method === "POST" && path === "/v1/auth/login") {
      const body = await readJson(req);
      const identity = readIdentity(body);
      const result = auth.loginOrRegister({
        ...identity,
        demoCode: optionalString(body.demoCode),
        displayName: optionalString(body.displayName),
        email: optionalString(body.email),
        phone: optionalString(body.phone),
      });
      send(res, 200, {
        ...result,
        identities: auth.listIdentities(result.session.token),
      });
      return;
    }

    const token = bearer(req);
    if (!token) throw new AuthError("not_authenticated", "session is missing or expired");

    if (req.method === "POST" && path === "/v1/auth/bind") {
      const body = await readJson(req);
      const identity = readIdentity(body);
      const result = auth.bindIdentity({
        sessionToken: token,
        ...identity,
        demoCode: optionalString(body.demoCode),
        displayName: optionalString(body.displayName),
        email: optionalString(body.email),
        phone: optionalString(body.phone),
      });
      send(res, 200, {
        ...result,
        identities: auth.listIdentities(result.session.token),
      });
      return;
    }

    if (req.method === "GET" && path === "/v1/auth/identities") {
      send(res, 200, { identities: auth.listIdentities(token) });
      return;
    }

    if (req.method === "DELETE" && path === "/v1/auth/identities") {
      const body = await readJson(req);
      const identity = readIdentity(body);
      auth.unbindIdentity({ sessionToken: token, ...identity });
      send(res, 200, { identities: auth.listIdentities(token) });
      return;
    }

    if (req.method === "POST" && path === "/v1/auth/logout") {
      auth.logout(token);
      send(res, 204, {});
      return;
    }

    send(res, 404, { error: { code: "not_found", message: "not found" } });
  } catch (error) {
    if (error instanceof AuthError) {
      send(res, statusFor(error.code), { error: { code: error.code, message: error.message } });
      return;
    }
    send(res, 500, { error: { code: "internal", message: "internal error" } });
  }
}
