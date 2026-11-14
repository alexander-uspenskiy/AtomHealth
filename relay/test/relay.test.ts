import { env, exports } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { cleanup } from "../src/index";

beforeEach(async () => {
  await env.DB.batch([env.DB.prepare("DELETE FROM changes"), env.DB.prepare("DELETE FROM devices")]);
});

const ADMIN = { "x-admin-code": "test-admin-code-0123456789" };
const exports_default = () => (exports as unknown as { default: Fetcher }).default;
const call = (path: string, init: RequestInit = {}) =>
  exports_default().fetch(new Request(`https://relay.test${path}`, init));
const post = (path: string, body: unknown, headers: Record<string, string> = {}) =>
  call(path, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

async function pairDevice(name: string): Promise<{ id: string; auth: Record<string, string> }> {
  const r = await post("/v1/pair", { name }, ADMIN);
  expect(r.status).toBe(201);
  const j = (await r.json()) as { device_id: string; token: string };
  return { id: j.device_id, auth: { authorization: `Bearer ${j.token}` } };
}

const rec = (id: string, text = "Zm9v") => ({ record_id: id, nonce: "bm9uY2U=", ciphertext: text });

describe("relay", () => {
  it("answers health without auth", async () => {
    const r = await call("/v1/health");
    expect(await r.json()).toEqual({ ok: true });
  });

  it("refuses plain HTTP and sends hardening headers", async () => {
    const r = await exports_default().fetch(new Request("http://relay.test/v1/health"));
    expect(r.status).toBe(403);
    const local = await exports_default().fetch(new Request("http://localhost/v1/health"));
    expect(local.status).toBe(200); // loopback exemption for wrangler dev
    const ok = await call("/v1/health");
    expect(ok.headers.get("strict-transport-security")).toContain("max-age=");
    expect(ok.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("requires the admin code to pair", async () => {
    expect((await post("/v1/pair", { name: "x" })).status).toBe(401);
    expect((await post("/v1/pair", { name: "x" }, { "x-admin-code": "wrong" })).status).toBe(401);
  });

  it("rejects requests without a valid device token", async () => {
    expect((await call("/v1/pull")).status).toBe(401);
    expect((await call("/v1/pull", { headers: { authorization: "Bearer abc.def" } })).status).toBe(401);
  });

  it("delivers records to the other device only", async () => {
    const phone = await pairDevice("phone");
    const mac = await pairDevice("mac");
    const pushed = await post("/v1/push", { records: [rec("record-0001"), rec("record-0002")] }, phone.auth);
    expect(pushed.status).toBe(200);

    const macPull = (await (await call("/v1/pull?since=0", { headers: mac.auth })).json()) as any;
    expect(macPull.records.map((r: any) => r.record_id)).toEqual(["record-0001", "record-0002"]);
    expect(macPull.next_seq).toBe(macPull.records[1].seq);

    const phonePull = (await (await call("/v1/pull?since=0", { headers: phone.auth })).json()) as any;
    expect(phonePull.records).toEqual([]);
    expect(phonePull.next_seq).toBe(macPull.next_seq); // cursor still advances past own rows
  });

  it("push is idempotent per (device, record_id)", async () => {
    const phone = await pairDevice("phone");
    const a = (await (await post("/v1/push", { records: [rec("record-0001")] }, phone.auth)).json()) as any;
    const b = (await (await post("/v1/push", { records: [rec("record-0001", "YmFy")] }, phone.auth)).json()) as any;
    expect(b.seqs).toEqual(a.seqs);
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM changes").first<{ n: number }>();
    expect(n?.n).toBe(1);
  });

  it("validates pushed records", async () => {
    const phone = await pairDevice("phone");
    expect((await post("/v1/push", { records: [] }, phone.auth)).status).toBe(400);
    expect((await post("/v1/push", { records: [rec("bad id!")] }, phone.auth)).status).toBe(400);
    expect((await post("/v1/push", { records: [rec("record-0001", "not base64 !!")] }, phone.auth)).status).toBe(400);
    const many = Array.from({ length: 51 }, (_, i) => rec(`record-${String(i).padStart(4, "0")}`));
    expect((await post("/v1/push", { records: many }, phone.auth)).status).toBe(400);
  });

  it("revoked devices lose access", async () => {
    const phone = await pairDevice("phone");
    const r = await call(`/v1/devices/${phone.id}`, { method: "DELETE", headers: ADMIN });
    expect(r.status).toBe(200);
    expect((await call("/v1/pull", { headers: phone.auth })).status).toBe(401);
  });

  it("caps the number of devices", async () => {
    for (let i = 0; i < 5; i++) await pairDevice(`d${i}`);
    expect((await post("/v1/pair", { name: "extra" }, ADMIN)).status).toBe(409);
  });

  it("cleanup removes only records every active device has acknowledged", async () => {
    const phone = await pairDevice("phone");
    const mac = await pairDevice("mac");
    await post("/v1/push", { records: [rec("record-0001"), rec("record-0002")] }, phone.auth);
    const pulled = (await (await call("/v1/pull?since=0", { headers: mac.auth })).json()) as any;
    const [first, second] = pulled.records.map((r: any) => r.seq);

    await post("/v1/ack", { cursor: second }, mac.auth);
    expect(await cleanup(env)).toBe(0); // phone has not acked yet

    await post("/v1/ack", { cursor: first }, phone.auth);
    expect(await cleanup(env)).toBe(1); // min cursor = first
    const left = await env.DB.prepare("SELECT seq FROM changes").all<{ seq: number }>();
    expect(left.results.map((r) => r.seq)).toEqual([second]);
  });

  it("cleanup enforces the retention cap", async () => {
    const phone = await pairDevice("phone");
    await post("/v1/push", { records: [rec("record-0001")] }, phone.auth);
    expect(await cleanup(env, Math.floor(Date.now() / 1000) + 31 * 24 * 3600)).toBe(1);
  });
});
