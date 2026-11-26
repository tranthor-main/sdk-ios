const { test } = require("node:test");
const assert = require("node:assert/strict");
const { createMockServer, BATCH_PATH } = require("./index.cjs");

async function setup(t) {
  const mock = createMockServer();
  const { host } = await mock.start();
  t.after(() => mock.close());
  const post = (route, body, headers = {}) => fetch(`${host}${route}`, {
    method: "POST", headers: { "Content-Type": "application/json", authorization: "Basic fixture", ...headers }, body: JSON.stringify(body),
  });
  const control = async (route, body) => (await post(`/control/${route}`, body)).json();
  const mint = async (sub, ttlSeconds = 3600, valid = true) => (await control("identity/token", { sub, ttlSeconds, valid })).token;
  const recorded = async () => (await (await fetch(`${host}/control/requests`)).json()).requests;
  const required = () => post("/control/identity", { mode: "required" });
  return { host, post, control, mint, recorded, required };
}

const item = (userId, extra = {}) => ({ type: "track", event: "e", messageId: `m-${userId}`, userId, ...extra });

test("the mock mints a token that decodes to the requested subject and expiry, and never repeats one", async (t) => {
  const { mint } = await setup(t);
  const first = await mint("user-1", 3600);
  const second = await mint("user-1", 3600);
  assert.notEqual(first, second);
  const payload = JSON.parse(Buffer.from(first.split(".")[1], "base64url").toString());
  assert.equal(payload.sub, "user-1");
  assert.equal(payload.exp - payload.iat, 3600);
});

test("off mode (the default) accepts items without tokens", async (t) => {
  const { post } = await setup(t);
  assert.equal((await post(BATCH_PATH, { batch: [item("user-1")] })).status, 204);
});

test("required mode answers 403 identity_not_verified with the user ids and the first reason, and stores nothing scripted", async (t) => {
  const { post, control, required, recorded } = await setup(t);
  await required();
  await control("script", { responses: [{ status: 500 }] });
  const response = await post(BATCH_PATH, { batch: [item("user-1"), item("user-2"), item("user-1")] });
  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), {
    message: "Identity token missing or invalid for 2 users.", code: "identity_not_verified", reason: "missing", userIds: ["user-1", "user-2"],
  });
  // The verdict is the server's own answer: the scripted 500 is still waiting for a request the mock accepts.
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 500);
  assert.equal((await recorded()).length, 2);
});

test("required mode accepts a batch whose users each carry a valid token, from the body or the header", async (t) => {
  const { post, mint, required } = await setup(t);
  await required();
  const batch = [item("user-1"), item("user-2"), { type: "page", anonymousId: "anon-1" }];
  assert.equal((await post(BATCH_PATH, { batch, identityTokens: [await mint("user-1"), await mint("user-2")] })).status, 204);
  assert.equal((await post(BATCH_PATH, { batch: [item("user-1")] }, { "x-tranthor-identity-token": await mint("user-1") })).status, 204);
});

test("required mode names why a token failed", async (t) => {
  const { post, mint, required } = await setup(t);
  await required();
  const reasonFor = async (token) => (await (await post(BATCH_PATH, { batch: [item("user-1")], identityTokens: [token] })).json()).reason;
  assert.equal(await reasonFor(await mint("user-1", 3600, false)), "signature");
  assert.equal(await reasonFor(await mint("user-1", -600)), "expired");
  assert.equal(await reasonFor("not-a-jwt"), "missing");
  // A token for another user does not verify this user.
  assert.equal(await reasonFor(await mint("user-2")), "missing");
});

test("a token that expired less than the 120 s tolerance ago still verifies", async (t) => {
  const { post, mint, required } = await setup(t);
  await required();
  assert.equal((await post(BATCH_PATH, { batch: [item("user-1")], identityTokens: [await mint("user-1", -60)] })).status, 204);
});

test("only the first 10 tokens are considered; extra tokens and users are not a 400", async (t) => {
  const { post, mint, required } = await setup(t);
  await required();
  const users = Array.from({ length: 11 }, (_, index) => `user-${index + 1}`);
  const identityTokens = await Promise.all(users.map((user) => mint(user)));
  const response = await post(BATCH_PATH, { batch: users.map((user) => item(user)), identityTokens });
  assert.equal(response.status, 403);
  assert.deepEqual((await response.json()).userIds, ["user-11"]);
  assert.equal((await post(BATCH_PATH, { batch: users.slice(0, 10).map((user) => item(user)), identityTokens })).status, 204);
  // 50 junk tokens in front: nothing rejects because of the count or the length.
  const junk = Array.from({ length: 50 }, () => "x".repeat(5000));
  const noisy = await post(BATCH_PATH, { batch: [item("user-1")], identityTokens: [...junk, identityTokens[0]] });
  assert.equal(noisy.status, 403);
  assert.equal((await noisy.json()).code, "identity_not_verified");
});

test("the header token comes before the body tokens when counting toward 10", async (t) => {
  const { post, mint, required } = await setup(t);
  await required();
  const others = await Promise.all(Array.from({ length: 10 }, (_, index) => mint(`other-${index}`)));
  const headerToken = await mint("user-1");
  assert.equal((await post(BATCH_PATH, { batch: [item("user-1")], identityTokens: others }, { "x-tranthor-identity-token": headerToken })).status, 204);
  assert.equal((await post(BATCH_PATH, { batch: [item("user-1")], identityTokens: [...others, headerToken] })).status, 403);
});

test("identityTokens that is not an array of strings is a 400 without a code, in every mode", async (t) => {
  const { post, required } = await setup(t);
  for (const identityTokens of ["abc", { a: 1 }, [1], ["ok", null]]) {
    const response = await post(BATCH_PATH, { batch: [], identityTokens });
    assert.equal(response.status, 400);
    assert.equal((await response.json()).code, undefined);
  }
  await required();
  assert.equal((await post(BATCH_PATH, { batch: [], identityTokens: 7 })).status, 400);
});

test("monitor mode accepts everything and counts unverified items in a response header", async (t) => {
  const { post, control, mint } = await setup(t);
  await control("identity", { mode: "monitor" });
  const response = await post(BATCH_PATH, { batch: [item("user-1"), item("user-2")], identityTokens: [await mint("user-1")] });
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("x-tranthor-unverified-events"), "1");
});

test("reset returns the mock to off mode, and an unknown mode is refused", async (t) => {
  const { post, required } = await setup(t);
  assert.equal((await post("/control/identity", { mode: "strict" })).status, 400);
  assert.equal((await post("/control/identity", {})).status, 400);
  await required();
  assert.equal((await post(BATCH_PATH, { batch: [item("user-1")] })).status, 403);
  await post("/control/reset", {});
  assert.equal((await post(BATCH_PATH, { batch: [item("user-1")] })).status, 204);
});

test("a scripted response can carry a JSON body", async (t) => {
  const { post, control } = await setup(t);
  await control("script", { responses: [{ status: 403, body: { code: "write_key_app_not_allowed", message: "no" } }, { status: 503, retryAfter: "30", body: { code: "identity_settings_unavailable" } }] });
  const first = await post(BATCH_PATH, { batch: [] });
  assert.equal(first.status, 403);
  assert.equal(first.headers.get("content-type"), "application/json");
  assert.deepEqual(await first.json(), { code: "write_key_app_not_allowed", message: "no" });
  const second = await post(BATCH_PATH, { batch: [] });
  assert.equal(second.headers.get("retry-after"), "30");
  assert.equal((await second.json()).code, "identity_settings_unavailable");
});

test("a script entry whose body is not an object is refused", async (t) => {
  const { post } = await setup(t);
  for (const body of ["text", 5, null, [1]]) assert.equal((await post("/control/script", { responses: [{ status: 403, body }] })).status, 400);
});

test("the mint route validates its input", async (t) => {
  const { post } = await setup(t);
  for (const body of [{}, { sub: "", ttlSeconds: 5 }, { sub: "u" }, { sub: "u", ttlSeconds: "5" }, { sub: "u", ttlSeconds: 5, valid: "no" }, { sub: "u", ttlSeconds: 5, extra: 1 }]) {
    assert.equal((await post("/control/identity/token", body)).status, 400);
  }
});

const sensitive = (extra) => ({ type: "track", messageId: "m-anon", anonymousId: "anon-1", ...extra });

test("required mode drops anonymous sensitive events, answers 204 and counts them in x-tranthor-dropped-events", async (t) => {
  const { post, required, recorded } = await setup(t);
  await required();
  const batch = [
    { type: "identify", messageId: "m1", anonymousId: "anon-1", traits: { email: "a@b.c" } },
    sensitive({ event: "Installation Registered" }),
    sensitive({ event: "Installation Removed" }),
    sensitive({ event: "TRSubscriptionChange" }),
    sensitive({ event: "DFSubscriptionChange" }),
    sensitive({ event: "Push Received" }),
    sensitive({ event: "Push Opened" }),
    sensitive({ event: "Push Dismissed" }),
    sensitive({ event: "Product Viewed" }),
    { type: "page", messageId: "m2", anonymousId: "anon-1" },
  ];
  const response = await post(BATCH_PATH, { batch });
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("x-tranthor-dropped-events"), "8");
  assert.equal((await recorded())[0].identity.dropped, 8);
});

test("anonymous sensitive events are accepted without a header in off mode, and without a drop for identified users with a token", async (t) => {
  const { post, mint, required } = await setup(t);
  const off = await post(BATCH_PATH, { batch: [sensitive({ event: "Installation Registered" })] });
  assert.equal(off.status, 204);
  assert.equal(off.headers.get("x-tranthor-dropped-events"), null);
  await required();
  const identified = await post(BATCH_PATH, {
    batch: [{ type: "track", messageId: "m", userId: "user-1", event: "Installation Registered" }],
    identityTokens: [await mint("user-1")],
  });
  assert.equal(identified.status, 204);
  assert.equal(identified.headers.get("x-tranthor-dropped-events"), null);
});

test("a token whose alg is not HS256 is refused with the reason signature", async (t) => {
  const { post, required } = await setup(t);
  await required();
  const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  for (const alg of ["none", "HS512"]) {
    const now = Math.floor(Date.now() / 1000);
    const token = `${b64({ alg, typ: "JWT" })}.${b64({ sub: "user-1", iat: now, exp: now + 3600 })}.`;
    const response = await post(BATCH_PATH, { batch: [item("user-1")], identityTokens: [token] });
    assert.equal(response.status, 403);
    assert.equal((await response.json()).reason, "signature", alg);
  }
});

test("an event over 64 KB is dropped and counted in x-tranthor-dropped-events in every mode", async (t) => {
  const { post, control } = await setup(t);
  const big = { type: "track", messageId: "m-big", anonymousId: "anon-1", event: "Big", properties: { blob: "x".repeat(65 * 1024) } };
  const small = { type: "track", messageId: "m-small", anonymousId: "anon-1", event: "Small" };
  for (const mode of ["off", "monitor", "required"]) {
    await control("identity", { mode });
    const response = await post(BATCH_PATH, { batch: [big, small] });
    assert.equal(response.status, 204, mode);
    assert.equal(response.headers.get("x-tranthor-dropped-events"), "1", mode);
  }
});

test("required mode keeps script order by arrival: a malformed body consumes an entry, an identity verdict does not", async (t) => {
  const { host, post, control, required } = await setup(t);
  await required();
  await control("script", { responses: [{ status: 500 }, { status: 429 }] });
  const malformed = await fetch(`${host}${BATCH_PATH}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{not json" });
  assert.equal(malformed.status, 400);
  assert.equal((await post(BATCH_PATH, { batch: [item("user-1")] })).status, 403);
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 429);
});

test("required mode gives concurrent requests their script entries in arrival order", async (t) => {
  const { post, control, required } = await setup(t);
  await required();
  await control("script", { responses: [{ status: 500, delayMs: 60 }, { status: 429 }] });
  const first = post(BATCH_PATH, { batch: [] });
  await new Promise((resolve) => setTimeout(resolve, 15));
  const second = post(BATCH_PATH, { batch: [] });
  assert.deepEqual((await Promise.all([first, second])).map((r) => r.status), [500, 429]);
});
