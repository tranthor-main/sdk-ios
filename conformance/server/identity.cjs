// Identity-token support for the mock ingestion server (suite 1.3.0). Node built-ins only.
//
// The mock models the server contract that the SDKs must respect: the `x-tranthor-identity-token` header and the
// `/batch` body field `identityTokens`, at most MAX_IDENTITY_TOKENS tokens considered per request, and in Required
// mode the 403 `identity_not_verified`. It uses a published fixture secret. It is a test double, not a verifier
// to trust: it does not model audiences, `kid` or secret rotation.
const crypto = require("node:crypto");

const FIXTURE_SECRET = "tr_idsec_conformance-fixture-not-a-secret";
const OTHER_SECRET = "tr_idsec_conformance-another-secret";
const MAX_IDENTITY_TOKENS = 10;
const MAX_TOKEN_BYTES = 2048;
const MAX_LIFETIME_SECONDS = 7 * 24 * 3600;
const CLOCK_TOLERANCE_SECONDS = 120;
const MAX_REPORTED_USER_IDS = 50;
// An event larger than this is dropped by the server in every mode and counted in x-tranthor-dropped-events.
const MAX_EVENT_BYTES = 64 * 1024;
const MODES = ["off", "monitor", "required"];
// Anonymous events that could change a customer. In required mode the server drops them with a 204.
const SENSITIVE_ANONYMOUS_EVENTS = [
  "Installation Registered", "Installation Removed", "TRSubscriptionChange", "DFSubscriptionChange",
  "Push Received", "Push Opened", "Push Dismissed",
];

const b64 = (value) => Buffer.from(typeof value === "string" ? value : JSON.stringify(value)).toString("base64url");
const sign = (input, secret) => crypto.createHmac("sha256", secret).update(input).digest("base64url");

// `valid: false` signs with a secret the server does not know, so the token has a good shape and a bad signature.
function mintToken({ sub, ttlSeconds, valid = true, nowMs = Date.now() }) {
  const iat = Math.floor(nowMs / 1000);
  const input = `${b64({ alg: "HS256", typ: "JWT" })}.${b64({ sub, iat, exp: iat + ttlSeconds, jti: crypto.randomUUID() })}`;
  return `${input}.${sign(input, valid ? FIXTURE_SECRET : OTHER_SECRET)}`;
}

function claimedSub(token) {
  try {
    const sub = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8")).sub;
    return typeof sub === "string" && sub ? sub : undefined;
  } catch { return undefined; }
}

// Returns { ok: true, sub } or { ok: false, reason, sub? }; reasons follow the server contract.
function verifyToken(token, nowMs = Date.now()) {
  if (typeof token !== "string" || Buffer.byteLength(token) > MAX_TOKEN_BYTES) return { ok: false, reason: "malformed" };
  const parts = token.split(".");
  if (parts.length !== 3) return { ok: false, reason: "malformed" };
  let header;
  let payload;
  try {
    header = JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8"));
    payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch { return { ok: false, reason: "malformed" }; }
  if (!payload || typeof payload !== "object" || typeof payload.sub !== "string" || !payload.sub) return { ok: false, reason: "malformed" };
  const sub = payload.sub;
  // As the server does: a token signed with any algorithm but HS256, `none` included, fails as a bad signature.
  if (!header || header.alg !== "HS256") return { ok: false, reason: "signature", sub };
  const expected = Buffer.from(sign(`${parts[0]}.${parts[1]}`, FIXTURE_SECRET));
  const actual = Buffer.from(parts[2]);
  if (expected.length !== actual.length || !crypto.timingSafeEqual(expected, actual)) return { ok: false, reason: "signature", sub };
  if (!Number.isFinite(payload.iat) || !Number.isFinite(payload.exp)) return { ok: false, reason: "malformed", sub };
  const nowSeconds = nowMs / 1000;
  if (payload.iat > nowSeconds + CLOCK_TOLERANCE_SECONDS) return { ok: false, reason: "not_yet_valid", sub };
  if (payload.exp - payload.iat > MAX_LIFETIME_SECONDS) return { ok: false, reason: "lifetime", sub };
  if (payload.exp + CLOCK_TOLERANCE_SECONDS <= nowSeconds) return { ok: false, reason: "expired", sub };
  return { ok: true, sub };
}

/**
 * Judges one ingestion request. Returns null when the request is accepted, or the verdict to send instead of a
 * scripted response: `{ status, body }`. `extraHeaders` carries response headers for an accepted request.
 *
 * - `identityTokens` that is not an array of strings is a 400 in every mode (a client bug, not a bad credential).
 *   Its length and the length of each token never reject a request.
 * - At most 10 tokens are considered, the header token first, then the body list in order. Later ones are ignored.
 * - Required: an item whose `userId` has no valid token for that same user fails the whole request with 403.
 *   Nothing is recorded as stored. Anonymous items need no token.
 * - Required also drops anonymous events that could change a customer (anonymous identify, Installation
 *   Registered/Removed, TRSubscriptionChange, DFSubscriptionChange, Push Received/Opened/Dismissed): the answer
 *   stays 2xx and `x-tranthor-dropped-events` carries the count, so the SDK has no error to react to.
 * - Monitor: never rejects; sets `x-tranthor-unverified-events` when items would fail.
 */
function judge({ mode, headers, body, nowMs = Date.now() }) {
  const result = { verdict: null, extraHeaders: {}, summary: { mode, verifiedUsers: [], unverifiedUsers: [] } };
  const bodyTokens = body && typeof body === "object" ? body.identityTokens : undefined;
  if (bodyTokens !== undefined && !(Array.isArray(bodyTokens) && bodyTokens.every((token) => typeof token === "string"))) {
    result.verdict = { status: 400, body: { message: "identityTokens must be an array of strings" } };
    return result;
  }
  const headerToken = headers["x-tranthor-identity-token"];
  const tokens = [...(typeof headerToken === "string" ? [headerToken] : []), ...(bodyTokens ?? [])].slice(0, MAX_IDENTITY_TOKENS);
  const verified = new Set();
  const failures = new Map();
  for (const token of tokens) {
    const outcome = verifyToken(token, nowMs);
    if (outcome.ok) verified.add(outcome.sub);
    else {
      const sub = outcome.sub ?? claimedSub(token);
      if (sub !== undefined && !failures.has(sub)) failures.set(sub, outcome.reason);
    }
  }
  const items = body && typeof body === "object" && Array.isArray(body.batch) ? body.batch : [];
  const users = [];
  let unverifiedItems = 0;
  let dropped = 0;
  let oversized = 0;
  for (const item of items) {
    if (Buffer.byteLength(JSON.stringify(item) ?? "") > MAX_EVENT_BYTES) { oversized++; continue; }
    const userId = item && typeof item === "object" ? item.userId : undefined;
    if (typeof userId !== "string" || userId === "") {
      const anonymousSensitive = item && typeof item === "object" &&
        (item.type === "identify" || (item.type === "track" && SENSITIVE_ANONYMOUS_EVENTS.includes(item.event)));
      if (anonymousSensitive) dropped++;
      continue;
    }
    if (verified.has(userId)) {
      if (!result.summary.verifiedUsers.includes(userId)) result.summary.verifiedUsers.push(userId);
    } else {
      unverifiedItems++;
      if (!users.includes(userId)) users.push(userId);
    }
  }
  result.summary.unverifiedUsers = users;
  // Oversized events are dropped in every mode; anonymous sensitive ones only in required.
  const totalDropped = oversized + (mode === "required" ? dropped : 0);
  if (totalDropped > 0) {
    result.summary.dropped = totalDropped;
    result.extraHeaders["x-tranthor-dropped-events"] = String(totalDropped);
  }
  if (mode === "monitor" && unverifiedItems > 0) result.extraHeaders["x-tranthor-unverified-events"] = String(unverifiedItems);
  if (mode === "required" && users.length > 0) {
    const first = users[0];
    result.verdict = {
      status: 403,
      body: {
        message: `Identity token missing or invalid for ${users.length} user${users.length === 1 ? "" : "s"}.`,
        code: "identity_not_verified",
        reason: failures.get(first) ?? "missing",
        userIds: users.slice(0, MAX_REPORTED_USER_IDS),
      },
    };
  }
  return result;
}

module.exports = { MODES, MAX_IDENTITY_TOKENS, FIXTURE_SECRET, mintToken, verifyToken, judge };
