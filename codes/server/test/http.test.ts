import assert from "node:assert/strict";
import { createServer } from "node:http";
import { after, before, describe, it } from "node:test";
import { DEMO_CODE, createAuthService } from "../src/auth-service.ts";
import { handleAuthRequest } from "../src/http.ts";

describe("auth http", () => {
  const auth = createAuthService();
  const server = createServer((req, res) => {
    void handleAuthRequest(auth, req, res);
  });
  let base = "";

  before(async () => {
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

  it("merges through login and bind, then refuses to drop the last identity", async () => {
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
});
