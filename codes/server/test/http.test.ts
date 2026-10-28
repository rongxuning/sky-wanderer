import assert from "node:assert/strict";
import { createServer } from "node:http";
import { after, before, describe, it } from "node:test";
import { DEMO_CODE, createAuthService } from "../src/auth-service.ts";
import { handleAuthRequest } from "../src/http.ts";
import { postgresBackend, type Backend } from "./support.ts";

describe("auth http", { concurrency: 1 }, () => {
  let backend: Backend;
  const server = createServer((req, res) => {
    void handleAuthRequest(backend.auth, req, res, { ready: () => backend.repo.ping() });
  });
  let base = "";

  before(async () => {
    backend = await postgresBackend();
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing port");
    base = `http://127.0.0.1:${address.port}`;
  });

  after(async () => {
    await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  });

  async function post(path: string, body: unknown, token?: string) {
    const response = await fetch(`${base}${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    });
    const text = await response.text();
    return { status: response.status, json: text ? (JSON.parse(text) as Record<string, unknown>) : {} };
  }

  it("reports health", async () => {
    const response = await fetch(`${base}/health`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true });
  });

  it("returns the demo code from send-code and merges through login and bind", async () => {
    const sent = await post("/v1/auth/phone/send-code", { phone: "13800138000" });
    assert.equal(sent.status, 200);
    assert.equal(sent.json.phone, "+8613800138000");
    assert.equal(sent.json.demoCode, DEMO_CODE);

    const earlier = await post("/v1/auth/login", {
      type: "wechat",
      providerSubject: "openid-http-early",
      displayName: "HTTP 早",
    });
    assert.equal(earlier.status, 200);
    const earlierUser = earlier.json.user as { id: string };
    const later = await post("/v1/auth/login", {
      type: "phone",
      providerSubject: "13800138000",
      demoCode: DEMO_CODE,
      displayName: "HTTP 晚",
    });
    assert.equal(later.status, 200);
    const laterSession = later.json.session as { token: string };

    const merged = await post(
      "/v1/auth/bind",
      { type: "wechat", providerSubject: "openid-http-early" },
      laterSession.token,
    );
    assert.equal(merged.status, 200);
    assert.equal((merged.json.user as { id: string }).id, earlierUser.id);
    assert.equal(merged.json.merged, true);
    assert.equal((merged.json.identities as unknown[]).length, 2);

    const removed = await fetch(`${base}/v1/auth/identities`, {
      method: "DELETE",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${laterSession.token}`,
      },
      body: JSON.stringify({ type: "phone", providerSubject: "+8613800138000" }),
    });
    assert.equal(removed.status, 200);

    const blocked = await fetch(`${base}/v1/auth/identities`, {
      method: "DELETE",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${laterSession.token}`,
      },
      body: JSON.stringify({ type: "wechat", providerSubject: "openid-http-early" }),
    });
    assert.equal(blocked.status, 409);
    const blockedBody = (await blocked.json()) as { error: { code: string } };
    assert.equal(blockedBody.error.code, "last_identity");

    const loggedOut = await fetch(`${base}/v1/auth/logout`, {
      method: "POST",
      headers: { authorization: `Bearer ${laterSession.token}` },
    });
    assert.equal(loggedOut.status, 204);
    const after = await fetch(`${base}/v1/auth/identities`, {
      headers: { authorization: `Bearer ${laterSession.token}` },
    });
    assert.equal(after.status, 401);
  });

  it("rejects a bad phone demo code", async () => {
    const response = await post("/v1/auth/login", {
      type: "phone",
      providerSubject: "+8613900139000",
      demoCode: "nope",
    });
    assert.equal(response.status, 400);
    assert.equal((response.json.error as { code: string }).code, "invalid_demo_code");
  });

  it("redirects provider callbacks into the app", async () => {
    const wechat = await fetch(`${base}/v1/auth/wechat/callback?code=abc&state=s1`, { redirect: "manual" });
    assert.equal(wechat.status, 302);
    assert.equal(wechat.headers.get("location"), "skywanderer://auth/wechat?code=abc&state=s1");

    const google = await fetch(`${base}/v1/auth/google/callback?error=access_denied&state=s2`, { redirect: "manual" });
    assert.equal(google.status, 302);
    const location = google.headers.get("location") ?? "";
    assert.ok(location.startsWith("skywanderer://auth/google?"));
    assert.match(location, /error=access_denied/);
    assert.match(location, /state=s2/);
  });

  it("does not trust a client openid when demo mode is off", async () => {
    const beforeUsers = (await backend.repo.listUsers()).length;
    const auth = createAuthService({ repo: backend.repo, demo: false, now: backend.time.now });
    const strict = createServer((req, res) => {
      void handleAuthRequest(auth, req, res);
    });
    await new Promise<void>((resolve) => strict.listen(0, "127.0.0.1", resolve));
    const address = strict.address();
    if (!address || typeof address === "string") throw new Error("missing port");
    const response = await fetch(`http://127.0.0.1:${address.port}/v1/auth/login`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "wechat", providerSubject: "client-openid" }),
    });
    assert.equal(response.status, 400);
    assert.equal(((await response.json()) as { error: { code: string } }).error.code, "invalid_subject");
    await new Promise<void>((resolve, reject) => strict.close((error) => (error ? reject(error) : resolve())));
    assert.equal((await backend.repo.listUsers()).length, beforeUsers);
  });
});
