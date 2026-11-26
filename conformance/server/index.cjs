const http = require("node:http");
const { MODES, mintToken, judge } = require("./identity.cjs");

const BATCH_PATH = "/api/public/apps/batch";
const MAX_BODY_BYTES = 1024 * 1024;

function validScript(script) {
  return Array.isArray(script) && script.every((entry) => {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return false;
    if (Object.keys(entry).some((key) => !["status", "delayMs", "retryAfter", "location", "drop", "body"].includes(key))) return false;
    if (entry.drop !== undefined && typeof entry.drop !== "boolean") return false;
    if (entry.body !== undefined && (entry.body === null || typeof entry.body !== "object" || Array.isArray(entry.body))) return false;
    if (entry.status !== undefined && (!Number.isInteger(entry.status) || entry.status < 200 || entry.status > 599)) return false;
    if (entry.delayMs !== undefined && (!Number.isInteger(entry.delayMs) || entry.delayMs < 0 || entry.delayMs > 30000)) return false;
    if (entry.retryAfter !== undefined && (typeof entry.retryAfter !== "string" || !/^[\x20-\x7e]*$(?![\s\S])/.test(entry.retryAfter) || !/^[0-9]+$(?![\s\S])/.test(entry.retryAfter))) return false;
    if (entry.location !== undefined && (typeof entry.location !== "string" || !/^[\x20-\x7e]*$(?![\s\S])/.test(entry.location))) return false;
    return entry.drop === true || entry.status !== undefined;
  });
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size <= MAX_BODY_BYTES) chunks.push(chunk);
    });
    request.on("error", reject);
    request.on("end", () => {
      if (size > MAX_BODY_BYTES) return reject(new Error("Body exceeds 1 MiB"));
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); }
      catch { reject(new Error("Invalid JSON")); }
    });
  });
}

function createMockServer() {
  let requests = [];
  let script = [];
  let cursor = 0;
  let generation = 0;
  let identityMode = "off";
  const delayed = new Map();
  const json = (response, status, body) => {
    response.writeHead(status, { "Content-Type": "application/json" });
    response.end(JSON.stringify(body));
  };
  const server = http.createServer(async (request, response) => {
    const receivedAtMs = Date.now();
    const requestGeneration = generation;
    const path = request.url;
    try {
      if (request.method === "POST" && path.startsWith("/control/") &&
          request.headers["content-type"]?.split(";", 1)[0].trim().toLowerCase() !== "application/json") {
        return json(response, 415, { error: "Control POST requires application/json" });
      }
      if (request.method === "GET" && path === "/control/time") {
        return json(response, 200, { nowMs: Date.now() });
      }
      if (request.method === "POST" && path === "/control/reset") {
        generation++;
        for (const [timer, pendingResponse] of delayed) {
          clearTimeout(timer);
          pendingResponse.destroy();
        }
        delayed.clear();
        requests = [];
        script = [];
        cursor = 0;
        identityMode = "off";
        return json(response, 200, { ok: true });
      }
      if (request.method === "POST" && path === "/control/identity") {
        const body = await readJson(request);
        if (!body || Object.keys(body).length !== 1 || !MODES.includes(body.mode)) {
          return json(response, 400, { error: `Expected { mode: ${MODES.join(" | ")} }` });
        }
        identityMode = body.mode;
        return json(response, 200, { ok: true });
      }
      if (request.method === "POST" && path === "/control/identity/token") {
        const body = await readJson(request);
        const keys = body && typeof body === "object" ? Object.keys(body) : [];
        if (!keys.length || keys.some((key) => !["sub", "ttlSeconds", "valid"].includes(key)) ||
            typeof body.sub !== "string" || !body.sub || !Number.isInteger(body.ttlSeconds) ||
            (body.valid !== undefined && typeof body.valid !== "boolean")) {
          return json(response, 400, { error: "Expected { sub: string, ttlSeconds: integer, valid?: boolean }" });
        }
        return json(response, 200, { token: mintToken(body) });
      }
      if (request.method === "POST" && path === "/control/script") {
        const body = await readJson(request);
        if (!body || Object.keys(body).length !== 1 || !validScript(body.responses)) {
          return json(response, 400, { error: "Expected { responses: [script entries] }" });
        }
        script = body.responses;
        cursor = 0;
        return json(response, 200, { ok: true });
      }
      if (request.method === "GET" && path === "/control/requests") {
        return json(response, 200, { requests });
      }
      if (request.method === "POST" && path === BATCH_PATH) {
        // Reserve script order at arrival, even if another body finishes reading first. In required mode the
        // server's own verdict may answer instead of the script, so the entry is taken after the body is read.
        let entry = identityMode === "required" ? undefined : script[cursor++] ?? { status: 204 };
        const record = {
          index: requests.length,
          receivedAtMs,
          method: request.method,
          path,
          headers: request.headers,
          body: null,
        };
        requests.push(record);
        try { record.body = await readJson(request); }
        catch (error) {
          record.parseError = error.message;
          return json(response, 400, { error: error.message });
        }
        if (requestGeneration !== generation) return response.destroy();
        const { verdict, extraHeaders, summary } = judge({ mode: identityMode, headers: request.headers, body: record.body });
        if (identityMode !== "off") record.identity = summary;
        // The verdict is the server's own answer, not a scripted one: it leaves the script untouched.
        if (verdict) return json(response, verdict.status, verdict.body);
        entry ??= script[cursor++] ?? { status: 204 };
        const respond = () => {
          try {
            if (entry.drop) return request.socket.destroy();
            response.writeHead(entry.status, {
              ...extraHeaders,
              ...(entry.retryAfter === undefined ? {} : { "Retry-After": entry.retryAfter }),
              ...(entry.location === undefined ? {} : { Location: entry.location }),
              ...(entry.body === undefined ? {} : { "Content-Type": "application/json" }),
            });
            response.end(entry.body === undefined ? undefined : JSON.stringify(entry.body));
          } catch {
            // Also contain errors from delayed callbacks, outside the request handler.
            response.destroy();
          }
        };
        if (entry.delayMs) {
          const timer = setTimeout(() => { delayed.delete(timer); respond(); }, entry.delayMs);
          delayed.set(timer, response);
        } else respond();
        return;
      }
      json(response, 404, { error: "Unknown route" });
    } catch (error) {
      json(response, 400, { error: error.message });
    }
  });
  return {
    server,
    async start(port = 0) {
      await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, "127.0.0.1", resolve);
      });
      return { port: server.address().port, host: `http://127.0.0.1:${server.address().port}` };
    },
    async close() {
      for (const [timer, response] of delayed) { clearTimeout(timer); response.destroy(); }
      delayed.clear();
      await new Promise((resolve, reject) => {
        server.close((error) => error ? reject(error) : resolve());
        server.closeAllConnections();
      });
    },
  };
}

module.exports = { createMockServer, validScript, BATCH_PATH };
