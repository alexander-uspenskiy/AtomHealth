// AtomHealth relay: an always-on, append-only mailbox for end-to-end encrypted sync records.
// The relay stores ciphertext only. Merge/conflict logic lives in the clients.

export interface Env {
  DB: D1Database;
  ADMIN_CODE: string;
}

const MAX_BODY_BYTES = 1_000_000;
const MAX_PUSH_RECORDS = 50; // keeps D1 queries/binds well inside free-plan limits
const MAX_CIPHERTEXT_B64 = 87_384; // ~64 KB of ciphertext
const MAX_PULL_LIMIT = 200;
const MAX_PULL_BYTES = 4_000_000;
const MAX_DEVICES = 5;
const RETENTION_SECONDS = 30 * 24 * 3600;
const LAST_SEEN_GRANULARITY = 300;
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

const RECORD_ID_RE = /^[A-Za-z0-9_-]{8,64}$/;
const B64_RE = /^[A-Za-z0-9+/_-]+={0,2}$/;

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
      "strict-transport-security": "max-age=63072000; includeSubDomains",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });

const now = () => Math.floor(Date.now() / 1000);

async function sha256(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");

async function safeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([sha256(a), sha256(b)]);
  // timingSafeEqual is a Workers-runtime extension of SubtleCrypto missing from some type bundles.
  return (crypto.subtle as unknown as { timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean }).timingSafeEqual(
    ha,
    hb,
  );
}

function randomToken(bytes: number): string {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function requireAdmin(req: Request, env: Env) {
  if (!env.ADMIN_CODE || env.ADMIN_CODE.length < 16) throw new HttpError(503, "admin code not configured");
  const given = req.headers.get("x-admin-code") ?? "";
  if (!(await safeEqual(given, env.ADMIN_CODE))) throw new HttpError(401, "bad admin code");
}

async function authDevice(req: Request, env: Env): Promise<string> {
  const m = /^Bearer ([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(req.headers.get("authorization") ?? "");
  if (!m) throw new HttpError(401, "missing or malformed token");
  const [, deviceId, secret] = m;
  const row = await env.DB.prepare("SELECT token_hash, revoked, last_seen FROM devices WHERE device_id=?1")
    .bind(deviceId)
    .first<{ token_hash: string; revoked: number; last_seen: number }>();
  const ok = row && !row.revoked && (await safeEqual(hex(await sha256(secret)), row.token_hash));
  if (!ok) throw new HttpError(401, "invalid token");
  const t = now();
  if (t - row.last_seen > LAST_SEEN_GRANULARITY) // avoid a D1 write on every request
    await env.DB.prepare("UPDATE devices SET last_seen=?1 WHERE device_id=?2").bind(t, deviceId).run();
  return deviceId;
}

async function readJson(req: Request): Promise<any> {
  const len = Number(req.headers.get("content-length") ?? 0);
  if (len > MAX_BODY_BYTES) throw new HttpError(413, "body too large");
  const text = await req.text();
  if (text.length > MAX_BODY_BYTES) throw new HttpError(413, "body too large");
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid JSON");
  }
}

// POST /v1/pair  (admin code) -> { device_id, token }
async function pair(req: Request, env: Env) {
  await requireAdmin(req, env);
  const body = await readJson(req);
  const name = typeof body?.name === "string" ? body.name.trim().slice(0, 64) : "";
  if (!name) throw new HttpError(400, "name required");
  const active = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices WHERE revoked=0").first<{ n: number }>();
  if ((active?.n ?? 0) >= MAX_DEVICES) throw new HttpError(409, "device limit reached");
  const deviceId = randomToken(9);
  const secret = randomToken(32);
  const t = now();
  await env.DB.prepare(
    "INSERT INTO devices(device_id,name,token_hash,cursor,created_at,last_seen) VALUES(?1,?2,?3,0,?4,?4)",
  )
    .bind(deviceId, name, hex(await sha256(secret)), t)
    .run();
  return json({ device_id: deviceId, token: `${deviceId}.${secret}` }, 201);
}

// DELETE /v1/devices/:id  (admin code) -> revoke
async function revoke(req: Request, env: Env, id: string) {
  await requireAdmin(req, env);
  const r = await env.DB.prepare("UPDATE devices SET revoked=1 WHERE device_id=?1").bind(id).run();
  if (!r.meta.changes) throw new HttpError(404, "no such device");
  return json({ revoked: id });
}

// POST /v1/push  { records: [{ record_id, nonce, ciphertext }] } -> { seqs: [{ record_id, seq }] }
async function push(req: Request, env: Env, deviceId: string) {
  const body = await readJson(req);
  const recs = body?.records;
  if (!Array.isArray(recs) || recs.length < 1 || recs.length > MAX_PUSH_RECORDS)
    throw new HttpError(400, `records must be an array of 1..${MAX_PUSH_RECORDS}`);
  for (const r of recs) {
    if (
      typeof r?.record_id !== "string" || !RECORD_ID_RE.test(r.record_id) ||
      typeof r?.nonce !== "string" || r.nonce.length > 64 || !B64_RE.test(r.nonce) ||
      typeof r?.ciphertext !== "string" || r.ciphertext.length > MAX_CIPHERTEXT_B64 || !B64_RE.test(r.ciphertext)
    )
      throw new HttpError(400, "invalid record");
  }
  const t = now();
  const ins = env.DB.prepare(
    "INSERT INTO changes(device_id,record_id,nonce,ciphertext,created_at) VALUES(?1,?2,?3,?4,?5) " +
      "ON CONFLICT(device_id,record_id) DO NOTHING",
  );
  await env.DB.batch(recs.map((r: any) => ins.bind(deviceId, r.record_id, r.nonce, r.ciphertext, t)));
  const ids = recs.map((r: any) => r.record_id);
  const marks = ids.map((_: string, i: number) => `?${i + 2}`).join(",");
  const { results } = await env.DB.prepare(
    `SELECT record_id, seq FROM changes WHERE device_id=?1 AND record_id IN (${marks})`,
  )
    .bind(deviceId, ...ids)
    .all<{ record_id: string; seq: number }>();
  return json({ seqs: results });
}

// GET /v1/pull?since=<seq>&limit=<n> -> records from OTHER devices
async function pull(req: Request, env: Env, deviceId: string) {
  const url = new URL(req.url);
  const since = Number(url.searchParams.get("since") ?? 0);
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 100), MAX_PULL_LIMIT);
  if (!Number.isInteger(since) || since < 0 || !Number.isInteger(limit) || limit < 1)
    throw new HttpError(400, "bad since/limit");
  const { results } = await env.DB.prepare(
    "SELECT seq, device_id, record_id, nonce, ciphertext, created_at FROM changes WHERE seq>?1 ORDER BY seq LIMIT ?2",
  )
    .bind(since, limit)
    .all<{ seq: number; device_id: string; record_id: string; nonce: string; ciphertext: string; created_at: number }>();
  const out = [];
  let bytes = 0;
  let nextSeq = since;
  let truncated = false;
  for (const r of results) {
    bytes += r.ciphertext.length + r.nonce.length;
    if (out.length > 0 && bytes > MAX_PULL_BYTES) {
      truncated = true;
      break;
    }
    nextSeq = r.seq; // advance past our own rows too, so the cursor never stalls
    if (r.device_id !== deviceId) out.push(r);
  }
  return json({ records: out, next_seq: nextSeq, has_more: truncated || results.length === limit });
}

// POST /v1/ack { cursor } -> records the highest seq this device has applied
async function ack(req: Request, env: Env, deviceId: string) {
  const body = await readJson(req);
  const cursor = body?.cursor;
  if (!Number.isInteger(cursor) || cursor < 0) throw new HttpError(400, "cursor must be a non-negative integer");
  await env.DB.prepare("UPDATE devices SET cursor=MAX(cursor,?1) WHERE device_id=?2").bind(cursor, deviceId).run();
  return json({ ok: true });
}

/** Delete records every active device has acknowledged, plus anything past the retention cap. */
export async function cleanup(env: Env, at = now()): Promise<number> {
  const active = await env.DB.prepare("SELECT COUNT(*) AS n, MIN(cursor) AS c FROM devices WHERE revoked=0").first<{
    n: number;
    c: number | null;
  }>();
  const minCursor = (active?.n ?? 0) >= 2 ? (active?.c ?? 0) : 0;
  const r = await env.DB.prepare("DELETE FROM changes WHERE seq<=?1 OR created_at<?2")
    .bind(minCursor, at - RETENTION_SECONDS)
    .run();
  return r.meta.changes ?? 0;
}

async function route(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  // Secrets (admin code, device tokens) must never travel over plain HTTP. workers.dev serves both.
  // Loopback is exempt so `wrangler dev` works; a deployed Worker is never reachable with that hostname.
  if (url.protocol !== "https:" && !LOOPBACK_HOSTS.has(url.hostname)) throw new HttpError(403, "https required");
  const p = url.pathname;
  const m = req.method;
  if (p === "/v1/health" && m === "GET") return json({ ok: true });
  if (p === "/v1/pair" && m === "POST") return pair(req, env);
  const dev = /^\/v1\/devices\/([A-Za-z0-9_-]+)$/.exec(p);
  if (dev && m === "DELETE") return revoke(req, env, dev[1]);
  if (p === "/v1/push" && m === "POST") return push(req, env, await authDevice(req, env));
  if (p === "/v1/pull" && m === "GET") return pull(req, env, await authDevice(req, env));
  if (p === "/v1/ack" && m === "POST") return ack(req, env, await authDevice(req, env));
  throw new HttpError(404, "not found");
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    try {
      return await route(req, env);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      console.error("relay error", e instanceof Error ? e.message : "unknown");
      return json({ error: "internal error" }, 500);
    }
  },
  async scheduled(_ev: ScheduledController, env: Env): Promise<void> {
    await cleanup(env);
  },
} satisfies ExportedHandler<Env>;
