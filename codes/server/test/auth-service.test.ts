import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { DEMO_CODE, createAuthService, type AuthStore } from "../src/auth-service.ts";

function clock(start: string) {
  let current = Date.parse(start);
  return {
    now: () => new Date(current),
    advance(ms: number) {
      current += ms;
    },
  };
}

function serviceAt(start: string, store: AuthStore = { users: [], identities: [], sessions: [], records: [] }) {
  const time = clock(start);
  let cursor = 0;
  const auth = createAuthService(store, {
    now: time.now,
    newId: () => `id-${cursor++}`,
  });
  return { auth, time, store };
}

describe("login or register by identity", () => {
  it("creates a user on first login and returns the same user the next time", () => {
    const { auth } = serviceAt("2026-01-01T00:00:00.000Z");

    const first = auth.loginOrRegister({
      type: "phone",
      providerSubject: "13800138000",
      demoCode: DEMO_CODE,
      displayName: "小林",
    });
    const second = auth.loginOrRegister({
      type: "phone",
      providerSubject: "+86 138-0013-8000",
      demoCode: DEMO_CODE,
    });

    assert.equal(first.created, true);
    assert.equal(second.created, false);
    assert.equal(second.user.id, first.user.id);
    assert.equal(second.user.displayName, "小林");
    assert.equal(auth.listIdentities(second.session.token).length, 1);
    assert.equal(auth.listIdentities(second.session.token)[0]?.providerSubject, "+8613800138000");
    assert.equal(auth.listIdentities(second.session.token)[0]?.type, "phone");
  });

  it("rejects a phone login whose demo code is not the local stub", () => {
    const { auth } = serviceAt("2026-01-01T00:00:00.000Z");
    assert.throws(
      () => auth.loginOrRegister({ type: "phone", providerSubject: "+8613800138000", demoCode: "000000" }),
      (error: { code?: string }) => error.code === "invalid_demo_code",
    );
  });

  it("accepts wechat and google stubs without a real provider token", () => {
    const { auth } = serviceAt("2026-01-01T00:00:00.000Z");
    const wechat = auth.loginOrRegister({ type: "wechat", providerSubject: "openid-wx-1" });
    const google = auth.loginOrRegister({
      type: "google",
      providerSubject: "google-sub-1",
      email: "walker@example.com",
    });
    assert.notEqual(wechat.user.id, google.user.id);
    assert.equal(google.user.email, "walker@example.com");
    assert.equal(wechat.user.displayName, "微信用户");
  });
});

describe("bind and merge", () => {
  it("binds a new identity onto the current user", () => {
    const { auth } = serviceAt("2026-01-01T00:00:00.000Z");
    const phone = auth.loginOrRegister({
      type: "phone",
      providerSubject: "+8613800138000",
      demoCode: DEMO_CODE,
    });

    const bound = auth.bindIdentity({
      sessionToken: phone.session.token,
      type: "google",
      providerSubject: "google-sub-9",
      email: "walker@example.com",
    });

    assert.equal(bound.merged, false);
    assert.equal(bound.user.id, phone.user.id);
    const types = auth.listIdentities(phone.session.token).map((identity) => identity.type).sort();
    assert.deepEqual(types, ["google", "phone"]);
  });

  it("is a no-op when the identity is already on the current user", () => {
    const { auth } = serviceAt("2026-01-01T00:00:00.000Z");
    const phone = auth.loginOrRegister({
      type: "phone",
      providerSubject: "+8613800138000",
      demoCode: DEMO_CODE,
    });
    const again = auth.bindIdentity({
      sessionToken: phone.session.token,
      type: "phone",
      providerSubject: "13800138000",
      demoCode: DEMO_CODE,
    });
    assert.equal(again.merged, false);
    assert.equal(again.user.id, phone.user.id);
    assert.equal(auth.listIdentities(phone.session.token).length, 1);
  });

  it("merges into the earlier account when the bound identity belongs to someone else", () => {
    const { auth, time, store } = serviceAt("2026-01-01T00:00:00.000Z");
    const earlier = auth.loginOrRegister({
      type: "wechat",
      providerSubject: "openid-early",
      displayName: "早的账号",
    });
    store.records.push({ id: "record-early", userId: earlier.user.id, kind: "note", payload: { text: "early" } });

    time.advance(60_000);
    const later = auth.loginOrRegister({
      type: "google",
      providerSubject: "google-late",
      email: "late@example.com",
      displayName: "晚的账号",
    });
    store.records.push({ id: "record-late", userId: later.user.id, kind: "note", payload: { text: "late" } });

    const merged = auth.bindIdentity({
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

    const loser = store.users.find((user) => user.id === later.user.id);
    assert.ok(loser?.retiredAt);
    assert.equal(loser?.mergedIntoUserId, earlier.user.id);
    assert.deepEqual(
      store.identities.map((identity) => identity.userId),
      [earlier.user.id, earlier.user.id],
    );
    assert.deepEqual(
      store.records.map((record) => record.userId),
      [earlier.user.id, earlier.user.id],
    );

    const fromWechat = auth.loginOrRegister({ type: "wechat", providerSubject: "openid-early" });
    const fromGoogle = auth.loginOrRegister({ type: "google", providerSubject: "google-late" });
    assert.equal(fromWechat.user.id, earlier.user.id);
    assert.equal(fromGoogle.user.id, earlier.user.id);
    assert.equal(fromGoogle.created, false);
  });

  it("keeps the earlier current user when binding a newer account's identity", () => {
    const { auth, time, store } = serviceAt("2026-03-01T00:00:00.000Z");
    const earlier = auth.loginOrRegister({
      type: "phone",
      providerSubject: "+8613900139000",
      demoCode: DEMO_CODE,
      displayName: "主账号",
    });
    time.advance(5_000);
    auth.loginOrRegister({
      type: "wechat",
      providerSubject: "openid-new",
      displayName: "新微信",
    });

    const merged = auth.bindIdentity({
      sessionToken: earlier.session.token,
      type: "wechat",
      providerSubject: "openid-new",
    });

    assert.equal(merged.merged, true);
    assert.equal(merged.user.id, earlier.user.id);
    assert.equal(merged.session.userId, earlier.user.id);
    assert.equal(store.users.filter((user) => user.retiredAt).map((user) => user.mergedIntoUserId).at(0), earlier.user.id);
    assert.equal(auth.listIdentities(earlier.session.token).length, 2);
  });

  it("breaks an identical createdAt tie by the smaller user id", () => {
    const store: AuthStore = { users: [], identities: [], sessions: [], records: [] };
    let cursor = 0;
    const auth = createAuthService(store, {
      now: () => new Date("2026-05-01T00:00:00.000Z"),
      newId: () => ["user-m", "user-a"][cursor++] ?? `id-${cursor}`,
    });
    const first = auth.loginOrRegister({ type: "wechat", providerSubject: "openid-m" });
    const second = auth.loginOrRegister({ type: "google", providerSubject: "google-a" });
    assert.equal(first.user.createdAt, second.user.createdAt);
    const smaller = [first.user.id, second.user.id].sort()[0];

    const merged = auth.bindIdentity({
      sessionToken: first.session.token,
      type: "google",
      providerSubject: "google-a",
    });
    assert.equal(merged.user.id, smaller);
    const retired = store.users.find((user) => user.retiredAt);
    assert.equal(retired?.mergedIntoUserId, smaller);
    assert.notEqual(retired?.id, smaller);
  });
});

describe("unbind", () => {
  it("removes an identity only when another one remains", () => {
    const { auth } = serviceAt("2026-01-01T00:00:00.000Z");
    const phone = auth.loginOrRegister({
      type: "phone",
      providerSubject: "+8613800138000",
      demoCode: DEMO_CODE,
    });
    auth.bindIdentity({
      sessionToken: phone.session.token,
      type: "google",
      providerSubject: "google-sub-2",
    });

    auth.unbindIdentity({
      sessionToken: phone.session.token,
      type: "google",
      providerSubject: "google-sub-2",
    });
    assert.deepEqual(
      auth.listIdentities(phone.session.token).map((identity) => identity.type),
      ["phone"],
    );

    assert.throws(
      () =>
        auth.unbindIdentity({
          sessionToken: phone.session.token,
          type: "phone",
          providerSubject: "+8613800138000",
        }),
      (error: { code?: string }) => error.code === "last_identity",
    );
    assert.equal(auth.listIdentities(phone.session.token).length, 1);
  });

  it("does not list or unbind identities for a missing session", () => {
    const { auth } = serviceAt("2026-01-01T00:00:00.000Z");
    assert.throws(() => auth.listIdentities("missing"), (error: { code?: string }) => error.code === "not_authenticated");
    assert.throws(
      () => auth.unbindIdentity({ sessionToken: "missing", type: "phone", providerSubject: "+8613800138000" }),
      (error: { code?: string }) => error.code === "not_authenticated",
    );
  });
});
