import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { loadConfig } from "../src/config.ts";
import { verifyGoogleIdToken } from "../src/oauth.ts";
import { aliyunSign, createAliyunSender, createSmsSender } from "../src/sms.ts";
import { googleKey, jsonResponse, signJwt } from "./support.ts";

describe("providers", () => {
  it("requires a database unless demo mode is on, and defaults the API host", () => {
    assert.throws(() => loadConfig({}), /DATABASE_URL is required unless AUTH_DEMO=1/);
    const config = loadConfig({ AUTH_DEMO: "1" });
    assert.equal(config.apiHost, "api.sky-wanderer.online");
    assert.deepEqual(config.googleRedirectUris, ["https://api.sky-wanderer.online/v1/auth/google/callback"]);
    assert.equal(config.demo, true);
    assert.equal(config.databaseUrl, "");
  });

  it("signs an Aliyun SMS request and refuses to send without credentials", async () => {
    const bodies: string[] = [];
    const sender = createAliyunSender({
      accessKeyId: "testid",
      accessKeySecret: "testsecret",
      signName: "Sky",
      templateCode: "SMS_1",
      now: () => new Date("2026-01-01T00:00:00.000Z"),
      nonce: () => "nonce-fixed",
      fetchImpl: async (input, init) => {
        assert.equal(String(input), "https://dysmsapi.aliyuncs.com/");
        bodies.push(String(init?.body ?? ""));
        return jsonResponse(200, { Code: "OK" });
      },
    });
    await sender.send("+8613800138000", "123456");
    const params = new URLSearchParams(bodies[0]);
    assert.equal(params.get("Action"), "SendSms");
    assert.equal(params.get("PhoneNumbers"), "+8613800138000");
    assert.equal(params.get("TemplateParam"), JSON.stringify({ code: "123456" }));
    const signed: Record<string, string> = {};
    for (const [key, value] of params) {
      if (key !== "Signature") signed[key] = value;
    }
    assert.equal(params.get("Signature"), aliyunSign(signed, "testsecret"));

    const missing = createSmsSender(
      {
        provider: "http",
        httpUrl: "",
        httpToken: "",
        aliyunAccessKeyId: "",
        aliyunAccessKeySecret: "",
        aliyunSignName: "",
        aliyunTemplateCode: "",
      },
      fetch,
    );
    assert.ok(missing);
    await assert.rejects(() => missing.send("+8613800138000", "123456"), (error: { code?: string }) => error.code === "sms_not_configured");
    assert.equal(
      createSmsSender(
        {
          provider: "",
          httpUrl: "",
          httpToken: "",
          aliyunAccessKeyId: "",
          aliyunAccessKeySecret: "",
          aliyunSignName: "",
          aliyunTemplateCode: "",
        },
        fetch,
      ),
      null,
    );
  });

  it("verifies a Google ID token and rejects a bad signature", async () => {
    const keys = googleKey();
    const certs = new Map((await keys.loadCerts()).map((item) => [item.kid, item.jwk]));
    const token = signJwt(keys.privateKey, {
      iss: "https://accounts.google.com",
      aud: "client.apps.googleusercontent.com",
      sub: "sub-1",
      exp: 2_000_000_000,
      email: "walker@example.com",
      email_verified: true,
    });
    const claims = await verifyGoogleIdToken(token, certs, ["client.apps.googleusercontent.com"], Date.parse("2026-01-01T00:00:00.000Z"));
    assert.equal(claims.sub, "sub-1");
    assert.equal(claims.email, "walker@example.com");

    const [header, , signature] = token.split(".");
    const tampered = `${header}.${Buffer.from("{}").toString("base64url")}.${signature}`;
    await assert.rejects(
      () => verifyGoogleIdToken(tampered, certs, ["client.apps.googleusercontent.com"], Date.parse("2026-01-01T00:00:00.000Z")),
      (error: { code?: string }) => error.code === "invalid_id_token",
    );
  });
});
