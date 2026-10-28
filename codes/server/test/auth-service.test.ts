import assert from "node:assert/strict";
import { before, beforeEach, describe, it } from "node:test";
import { DEMO_CODE, createAuthService, type AuthService } from "../src/auth-service.ts";
import { jsonResponse, memoryBackend, postgresBackend, signJwt, googleKey, type Backend } from "./support.ts";

function register(name: string, open: () => Promise<Backend> | Backend) {
  describe(name, { concurrency: 1 }, () => {
    let backend: Backend;

    before(async () => {
      backend = await open();
    });

    beforeEach(async () => {
      await backend.reset();
    });

    it("creates a user on first login and returns the same user the next time", async () => {
      const { auth } = backend;
      const first = await auth.loginOrRegister({
        type: "phone",
        providerSubject: "13800138000",
        demoCode: DEMO_CODE,
        displayName: "小林",
      });
      const second = await auth.loginOrRegister({
        type: "phone",
        providerSubject: "+86 138-0013-8000",
        demoCode: DEMO_CODE,
      });

      assert.equal(first.created, true);
      assert.equal(second.created, false);
      assert.equal(second.user.id, first.user.id);
      assert.equal(second.user.displayName, "小林");
      const identities = await auth.listIdentities(second.session.token);
      assert.equal(identities.length, 1);
      assert.equal(identities[0]?.providerSubject, "+8613800138000");
      assert.equal(identities[0]?.type, "phone");
    });

    it("rejects a phone login whose demo code is not the local stub", async () => {
      const { auth } = backend;
      await assert.rejects(
        () => auth.loginOrRegister({ type: "phone", providerSubject: "+8613800138000", demoCode: "000000" }),
        (error: { code?: string }) => error.code === "invalid_demo_code",
      );
    });

    it("accepts wechat and google stubs without a real provider token", async () => {
      const { auth } = backend;
      const wechat = await auth.loginOrRegister({ type: "wechat", providerSubject: "openid-wx-1" });
      const google = await auth.loginOrRegister({
        type: "google",
        providerSubject: "google-sub-1",
        email: "walker@example.com",
      });
      assert.notEqual(wechat.user.id, google.user.id);
      assert.equal(google.user.email, "walker@example.com");
      assert.equal(wechat.user.displayName, "微信用户");
    });

    it("returns the demo code when SMS is not configured", async () => {
      const sent = await backend.auth.sendPhoneCode("13800138000");
      assert.equal(sent.phone, "+8613800138000");
      assert.equal(sent.demoCode, DEMO_CODE);
    });

    it("binds a new identity onto the current user", async () => {
      const { auth } = backend;
      const phone = await auth.loginOrRegister({
        type: "phone",
        providerSubject: "+8613800138000",
        demoCode: DEMO_CODE,
      });
      const bound = await auth.bindIdentity({
        sessionToken: phone.session.token,
        type: "google",
        providerSubject: "google-sub-9",
        email: "walker@example.com",
      });
      assert.equal(bound.merged, false);
      assert.equal(bound.user.id, phone.user.id);
      const types = (await auth.listIdentities(phone.session.token)).map((identity) => identity.type).sort();
      assert.deepEqual(types, ["google", "phone"]);
    });

    it("is a no-op when the identity is already on the current user", async () => {
      const { auth } = backend;
      const phone = await auth.loginOrRegister({
        type: "phone",
        providerSubject: "+8613800138000",
        demoCode: DEMO_CODE,
      });
      const again = await auth.bindIdentity({
        sessionToken: phone.session.token,
        type: "phone",
        providerSubject: "13800138000",
        demoCode: DEMO_CODE,
      });
      assert.equal(again.merged, false);
      assert.equal(again.user.id, phone.user.id);
      assert.equal((await auth.listIdentities(phone.session.token)).length, 1);
    });

    it("merges into the earlier account when the bound identity belongs to someone else", async () => {
      const { auth, time, repo } = backend;
      const earlier = await auth.loginOrRegister({
        type: "wechat",
        providerSubject: "openid-early",
        displayName: "早的账号",
      });
      await repo.insertRecord({ id: "record-early", userId: earlier.user.id, kind: "note", payload: { text: "early" } });

      time.advance(60_000);
      const later = await auth.loginOrRegister({
        type: "google",
        providerSubject: "google-late",
        email: "late@example.com",
        displayName: "晚的账号",
      });
      await repo.insertRecord({ id: "record-late", userId: later.user.id, kind: "note", payload: { text: "late" } });

      const merged = await auth.bindIdentity({
        sessionToken: later.session.token,
        type: "wechat",
        providerSubject: "openid-early",
      });

      assert.equal(merged.merged, true);
      assert.equal(merged.user.id, earlier.user.id);
      assert.equal(merged.user.displayName, "早的账号");
      assert.equal(merged.user.email, "late@example.com");
      assert.equal(merged.session.userId, earlier.user.id);
      assert.equal(merged.session.token, later.session.token);

      const users = await repo.listUsers();
      const loser = users.find((user) => user.id === later.user.id);
      assert.ok(loser?.retiredAt);
      assert.equal(loser?.mergedIntoUserId, earlier.user.id);
      assert.equal(users.find((user) => user.id === earlier.user.id)?.email, "late@example.com");
      assert.deepEqual(
        (await repo.listIdentities()).map((identity) => identity.userId),
        [earlier.user.id, earlier.user.id],
      );
      assert.deepEqual(
        (await repo.listRecords()).map((record) => record.userId),
        [earlier.user.id, earlier.user.id],
      );

      const fromWechat = await auth.loginOrRegister({ type: "wechat", providerSubject: "openid-early" });
      const fromGoogle = await auth.loginOrRegister({ type: "google", providerSubject: "google-late" });
      assert.equal(fromWechat.user.id, earlier.user.id);
      assert.equal(fromGoogle.user.id, earlier.user.id);
      assert.equal(fromGoogle.created, false);
    });

    it("keeps the earlier current user when binding a newer account's identity", async () => {
      const { auth, time, repo } = backend;
      time.set("2026-03-01T00:00:00.000Z");
      const earlier = await auth.loginOrRegister({
        type: "phone",
        providerSubject: "+8613900139000",
        demoCode: DEMO_CODE,
        displayName: "主账号",
      });
      time.advance(5_000);
      await auth.loginOrRegister({
        type: "wechat",
        providerSubject: "openid-new",
        displayName: "新微信",
      });

      const merged = await auth.bindIdentity({
        sessionToken: earlier.session.token,
        type: "wechat",
        providerSubject: "openid-new",
      });

      assert.equal(merged.merged, true);
      assert.equal(merged.user.id, earlier.user.id);
      assert.equal(merged.session.userId, earlier.user.id);
      const retired = (await repo.listUsers()).filter((user) => user.retiredAt);
      assert.equal(retired.map((user) => user.mergedIntoUserId).at(0), earlier.user.id);
      assert.equal((await auth.listIdentities(earlier.session.token)).length, 2);
    });

    it("breaks an identical createdAt tie by the smaller user id", async () => {
      const { repo, time } = backend;
      let cursor = 0;
      const auth = createAuthService({
        repo,
        demo: true,
        now: time.now,
        newId: () => ["user-m", "user-a"][cursor++] ?? `id-${cursor}`,
      });
      const first = await auth.loginOrRegister({ type: "wechat", providerSubject: "openid-m" });
      const second = await auth.loginOrRegister({ type: "google", providerSubject: "google-a" });
      assert.equal(first.user.createdAt, second.user.createdAt);
      const smaller = [first.user.id, second.user.id].sort()[0];

      const merged = await auth.bindIdentity({
        sessionToken: first.session.token,
        type: "google",
        providerSubject: "google-a",
      });
      assert.equal(merged.user.id, smaller);
      const retired = (await repo.listUsers()).find((user) => user.retiredAt);
      assert.equal(retired?.mergedIntoUserId, smaller);
      assert.notEqual(retired?.id, smaller);
    });

    it("removes an identity only when another one remains", async () => {
      const { auth } = backend;
      const phone = await auth.loginOrRegister({
        type: "phone",
        providerSubject: "+8613800138000",
        demoCode: DEMO_CODE,
      });
      await auth.bindIdentity({
        sessionToken: phone.session.token,
        type: "google",
        providerSubject: "google-sub-2",
      });
      await auth.unbindIdentity({
        sessionToken: phone.session.token,
        type: "google",
        providerSubject: "google-sub-2",
      });
      assert.deepEqual(
        (await auth.listIdentities(phone.session.token)).map((identity) => identity.type),
        ["phone"],
      );
      await assert.rejects(
        () =>
          auth.unbindIdentity({
            sessionToken: phone.session.token,
            type: "phone",
            providerSubject: "+8613800138000",
          }),
        (error: { code?: string }) => error.code === "last_identity",
      );
      assert.equal((await auth.listIdentities(phone.session.token)).length, 1);
    });

    it("does not list or unbind identities for a missing session", async () => {
      const { auth } = backend;
      await assert.rejects(
        () => auth.listIdentities("missing"),
        (error: { code?: string }) => error.code === "not_authenticated",
      );
      await assert.rejects(
        () => auth.unbindIdentity({ sessionToken: "missing", type: "phone", providerSubject: "+8613800138000" }),
        (error: { code?: string }) => error.code === "not_authenticated",
      );
    });

    it("drops a session on logout and after it expires", async () => {
      const { repo, time } = backend;
      const auth = createAuthService({
        repo,
        demo: true,
        now: time.now,
        newId: () => `exp-${Math.random()}`,
        sessionTtlMs: 1_000,
      });
      const phone = await auth.loginOrRegister({
        type: "phone",
        providerSubject: "+8613700137000",
        demoCode: DEMO_CODE,
      });
      await auth.logout(phone.session.token);
      await assert.rejects(
        () => auth.listIdentities(phone.session.token),
        (error: { code?: string }) => error.code === "not_authenticated",
      );

      const again = await auth.loginOrRegister({
        type: "phone",
        providerSubject: "+8613700137000",
        demoCode: DEMO_CODE,
      });
      time.advance(1_001);
      await assert.rejects(
        () => auth.listIdentities(again.session.token),
        (error: { code?: string }) => error.code === "not_authenticated",
      );
    });

    it("uses provider results and ignores client-supplied subjects", async () => {
      await productionCases(backend);
    });
  });
}

async function productionCases(backend: Backend) {
  const { repo, time } = backend;
  const sent: { phone: string; code: string }[] = [];
  const keys = googleKey();
  const redirect = "https://api.sky-wanderer.online/v1/auth/google/callback";
  const clientId = "sky-ios.apps.googleusercontent.com";
  const idToken = signJwt(keys.privateKey, {
    iss: "https://accounts.google.com",
    aud: clientId,
    sub: "google-real",
    exp: 2_000_000_000,
    email: "walker@example.com",
    email_verified: true,
    name: "Walker",
    nonce: "nonce-1",
  });

  const auth: AuthService = createAuthService({
    repo,
    demo: false,
    now: time.now,
    newId: () => `prod-${Math.random().toString(16).slice(2)}`,
    sms: {
      async send(phone, code) {
        sent.push({ phone, code });
      },
    },
    wechat: { appId: "wx-app", appSecret: "wx-secret" },
    googleClientIds: [clientId],
    googleClientSecret: "google-secret",
    googleRedirectUris: [redirect],
    loadGoogleCerts: keys.loadCerts,
    fetch: async (input, init) => {
      const href = typeof input === "string" ? input : input.href;
      if (href.includes("oauth2.googleapis.com/token")) {
        const body = String(init?.body ?? "");
        assert.match(body, /google-secret/);
        assert.match(body, /code-from-google/);
        return jsonResponse(200, { id_token: idToken });
      }
      if (href.includes("/sns/oauth2/access_token")) {
        assert.match(href, /code=wechat-code/);
        assert.match(href, /secret=wx-secret/);
        return jsonResponse(200, { openid: "openid-from-wechat", access_token: "at" });
      }
      if (href.includes("/sns/userinfo")) return jsonResponse(200, { nickname: "阿天" });
      throw new Error(`unexpected fetch ${href}`);
    },
  });

  await assert.rejects(
    () => auth.sendPhoneCode("13800138000").then(() => auth.sendPhoneCode("13800138000")),
    (error: { code?: string }) => error.code === "sms_rate_limited",
  );
  time.advance(61_000);
  const issued = await auth.sendPhoneCode("+86 138-0013-8000");
  assert.equal(issued.phone, "+8613800138000");
  assert.equal(issued.demoCode, undefined);
  assert.equal(sent.at(-1)?.phone, "+8613800138000");

  await assert.rejects(
    () => auth.loginOrRegister({ type: "phone", providerSubject: "13800138000", smsCode: "000000" }),
    (error: { code?: string }) => error.code === "invalid_sms_code",
  );
  const phone = await auth.loginOrRegister({
    type: "phone",
    providerSubject: "13800138000",
    smsCode: sent.at(-1)?.code,
  });
  assert.equal(phone.created, true);
  await assert.rejects(
    () => auth.loginOrRegister({ type: "phone", providerSubject: "+8613800138000", smsCode: sent.at(-1)?.code }),
    (error: { code?: string }) => error.code === "invalid_sms_code",
  );

  await assert.rejects(
    () => auth.loginOrRegister({ type: "wechat", providerSubject: "client-openid" }),
    (error: { code?: string }) => error.code === "invalid_subject",
  );
  const wechat = await auth.loginOrRegister({
    type: "wechat",
    providerSubject: "client-openid",
    authorizationCode: "wechat-code",
    displayName: "伪造",
  });
  assert.equal(wechat.user.displayName, "阿天");
  assert.equal((await auth.listIdentities(wechat.session.token))[0]?.providerSubject, "openid-from-wechat");

  await assert.rejects(
    () => auth.loginOrRegister({ type: "google", providerSubject: "client-sub" }),
    (error: { code?: string }) => error.code === "invalid_subject",
  );
  const google = await auth.loginOrRegister({
    type: "google",
    providerSubject: "client-sub",
    email: "evil@example.com",
    idToken,
    nonce: "nonce-1",
  });
  assert.equal(google.user.email, "walker@example.com");
  assert.equal(google.user.displayName, "Walker");
  assert.equal((await auth.listIdentities(google.session.token))[0]?.providerSubject, "google-real");

  const exchanged = await auth.loginOrRegister({
    type: "google",
    authorizationCode: "code-from-google",
    codeVerifier: "verifier-1",
    redirectUri: redirect,
    clientId,
    nonce: "nonce-1",
  });
  assert.equal(exchanged.created, false);
  assert.equal(exchanged.user.id, google.user.id);

  const bare = createAuthService({ repo, demo: false, now: time.now });
  await assert.rejects(
    () => bare.sendPhoneCode("+8613800138000"),
    (error: { code?: string }) => error.code === "sms_not_configured",
  );
}

register("auth memory", () => memoryBackend());
register("auth postgres", () => postgresBackend());
