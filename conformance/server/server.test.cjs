const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const { once } = require("node:events");
const { createMockServer, validScript, BATCH_PATH } = require("./index.cjs");

async function setup(t) {
  const mock = createMockServer();
  const { host } = await mock.start();
  t.after(() => mock.close());
  const post = (route, body) => fetch(`${host}${route}`, {
    method: "POST", headers: { "Content-Type": "application/json", authorization: "Basic fixture" }, body: JSON.stringify(body),
  });
  const recorded = async () => (await (await fetch(`${host}/control/requests`)).json()).requests;
  return { mock, host, post, recorded };
}

test("binds only to IPv4 loopback and records body, headers, arrival time and order", async (t) => {
  const { mock, post, recorded } = await setup(t);
  assert.equal(mock.server.address().address, "127.0.0.1");
  const before = Date.now();
  assert.equal((await post(BATCH_PATH, { batch: [{ event: "first" }] })).status, 204);
  assert.equal((await post(BATCH_PATH, { batch: [{ event: "second" }] })).status, 204);
  const requests = await recorded();
  assert.deepEqual(requests.map((request) => request.index), [0, 1]);
  assert.deepEqual(requests[0].body, { batch: [{ event: "first" }] });
  assert.equal(requests[0].headers.authorization, "Basic fixture");
  assert.equal(requests[0].headers["content-type"], "application/json");
  assert.equal(requests[0].path, BATCH_PATH);
  assert.equal(requests[0].method, "POST");
  assert(requests[0].receivedAtMs >= before && requests[0].receivedAtMs <= Date.now());
});

test("consumes scripted status, delay and Retry-After then defaults to 204", async (t) => {
  const { post, recorded } = await setup(t);
  assert.equal((await post("/control/script", { responses: [{ status: 429, delayMs: 70, retryAfter: "1" }, { status: 401 }] })).status, 200);
  const start = Date.now();
  const first = await post(BATCH_PATH, { batch: [] });
  assert.equal(first.status, 429);
  assert.equal(first.headers.get("retry-after"), "1");
  assert(Date.now() - start >= 60);
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 401);
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 204);
  assert.equal((await recorded()).length, 3);
});

test("records a dropped socket before the client rejects", async (t) => {
  const { post, recorded } = await setup(t);
  await post("/control/script", { responses: [{ drop: true }] });
  await assert.rejects(post(BATCH_PATH, { batch: [{ messageId: "stable" }] }));
  assert.equal((await recorded())[0].body.batch[0].messageId, "stable");
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 204);
});

test("reset clears both observations and script cursor; script reload keeps observations", async (t) => {
  const { post, recorded } = await setup(t);
  await post("/control/script", { responses: [{ status: 500 }, { status: 403 }] });
  await post(BATCH_PATH, { batch: [] });
  await post("/control/script", { responses: [{ status: 425 }] });
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 425);
  assert.equal((await recorded()).length, 2);
  await post("/control/reset", {});
  assert.deepEqual(await recorded(), []);
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 204);
});

test("rejects invalid scripts atomically without replacing the valid script", async (t) => {
  const { post } = await setup(t);
  await post("/control/script", { responses: [{ status: 500 }] });
  for (const entry of [{ status: 199 }, { status: 600 }, { delayMs: -1, status: 200 }, { drop: "yes" }, { status: 200, retryAfter: "1\r\nBad: header" }, { status: 200, typo: 1 }, {}]) {
    assert.equal((await post("/control/script", { responses: [entry] })).status, 400);
  }
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 500);
});

test("malformed JSON is recorded with a parse error and gets 400; wrong routes get 404", async (t) => {
  const { host, recorded } = await setup(t);
  const response = await fetch(`${host}${BATCH_PATH}`, { method: "POST", body: "{" });
  assert.equal(response.status, 400);
  assert.equal((await recorded())[0].parseError, "Invalid JSON");
  assert.equal((await fetch(`${host}/not-a-route`)).status, 404);
  assert.equal((await fetch(`${host}${BATCH_PATH}`)).status, 404);
});

test("reset cancels a delayed response and does not contaminate the next run", async (t) => {
  const { host, post, recorded } = await setup(t);
  await post("/control/script", { responses: [{ status: 500, delayMs: 500 }] });
  const pending = post(BATCH_PATH, { batch: [] }).catch(() => null);
  while (!(await recorded()).length) await new Promise((resolve) => setTimeout(resolve, 5));
  await post("/control/reset", {});
  assert.equal(await pending, null);
  assert.deepEqual(await recorded(), []);
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 204);
});

test("CLI port zero prints machine-readable chosen port and exits on SIGTERM", async (t) => {
  const child = spawn(process.execPath, [require.resolve("./cli.cjs"), "--port", "0"]);
  t.after(() => { if (child.exitCode === null) child.kill("SIGKILL"); });
  const [chunk] = await once(child.stdout, "data");
  const address = JSON.parse(chunk.toString());
  assert(address.port > 0);
  assert.equal(address.host, `http://127.0.0.1:${address.port}`);
  assert.equal((await fetch(`${address.host}/control/requests`)).status, 200);
  const exit = once(child, "exit");
  child.kill("SIGTERM");
  assert.equal((await exit)[0], 0);
});

test("control POSTs require JSON media type without changing records or scripts", async (t) => {
  const { host, post, recorded } = await setup(t);
  await post("/control/script", { responses: [{ status: 401 }] });
  await post(BATCH_PATH, { batch: [] });
  await post("/control/script", { responses: [{ status: 500 }] });
  for (const route of ["reset", "script"]) {
    for (const headers of [{}, { "Content-Type": "text/plain" }]) {
      assert.equal((await fetch(`${host}/control/${route}`, { method: "POST", headers, body: "{}" })).status, 415);
    }
  }
  assert.equal((await recorded()).length, 1);
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 500);
  assert.equal((await fetch(`${host}/control/reset`, { method: "POST", headers: { "Content-Type": "Application/JSON; charset=utf-8" }, body: "{}" })).status, 200);
});

test("unsafe delayed headers and non-digit Retry-After are rejected atomically", async (t) => {
  const { post } = await setup(t);
  await post("/control/script", { responses: [{ status: 403 }] });
  for (const retryAfter of ["Ā", "\u0000", "\u007f", "1\n", "1\r\n", "1.5", "1e3", "0x10", "-1", "Thu, 01 Jan 1970 00:00:00 GMT"]) {
    const entry = { status: 429, delayMs: 1, retryAfter };
    assert.equal(validScript([entry]), false);
    assert.equal((await post("/control/script", { responses: [entry] })).status, 400);
  }
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 403);
});

test("delayed response write errors cannot escape the callback or kill the server", async (t) => {
  const { post } = await setup(t);
  const { ServerResponse } = require("node:http");
  const original = ServerResponse.prototype.writeHead;
  ServerResponse.prototype.writeHead = function (status, ...args) {
    if (status === 429) throw new Error("Injected invalid header write");
    return original.call(this, status, ...args);
  };
  t.after(() => { ServerResponse.prototype.writeHead = original; });
  await post("/control/script", { responses: [{ status: 429, delayMs: 10 }] });
  await assert.rejects(post(BATCH_PATH, { batch: [] }));
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 204);
});

test("control time returns the server clock without consuming script or recording", async (t) => {
  const { host, post, recorded } = await setup(t);
  await post("/control/script", { responses: [{ status: 401 }] });
  const before = Date.now();
  const response = await fetch(`${host}/control/time`);
  assert.equal(response.status, 200);
  const { nowMs } = await response.json();
  assert(nowMs >= before && nowMs <= Date.now());
  assert.deepEqual(await recorded(), []);
  assert.equal((await post(BATCH_PATH, { batch: [] })).status, 401);
});

test("scripted Location headers use printable ASCII and redirect responses stay literal", async (t) => {
  const { host, post } = await setup(t);
  assert.equal(validScript([{ status: 302, location: "Ā" }]), false);
  assert.equal(validScript([{ status: 302, location: "ok\n" }]), false);
  assert.equal((await post("/control/script", { responses: [{ status: 302, delayMs: 1, location: "Ā" }] })).status, 400);
  await post("/control/script", { responses: [{ status: 302, location: "/redirect-target" }] });
  const response = await fetch(`${host}${BATCH_PATH}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}", redirect: "manual" });
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), "/redirect-target");
});
