import assert from "node:assert/strict";
import { createServer, request } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { BodyTooLong, readJsonCapped } from "../src/body.js";
import { toNodeHandler } from "../src/node.js";

test("the Node adapter passes large bodies through, and answers 413 past its limits", async () => {
  const seen: number[] = [];
  const handler = toNodeHandler(async (request) => {
    seen.push((await request.text()).length);
    return new Response("{}", { headers: { "content-type": "application/json" } });
  });
  const server = createServer((req, res) => void handler(req, res));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  try {
    const rows = "x".repeat(300 * 1024);
    const big = await fetch(`${base}/runlight/api/links/import`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ rows }) });
    assert.equal(big.status, 200);
    assert.equal(seen.at(-1), rows.length + 11, "a 300 KB import arrives whole");
    const collect = await fetch(`${base}/runlight/e`, { method: "POST", body: "x".repeat(20 * 1024) });
    assert.equal(collect.status, 413, "the collect endpoint keeps its small limit");
  } finally {
    server.close();
  }
});

async function serve(handler: Parameters<typeof toNodeHandler>[0]) {
  const node = toNodeHandler(handler);
  const server = createServer((req, res) => void node(req, res));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, port: (server.address() as AddressInfo).port };
}

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

test("the Node adapter streams a body only as fast as the client reads, and stops reading when it leaves", async () => {
  let pulled = 0;
  let cancelled = false;
  const chunk = new Uint8Array(1024 * 1024);
  const { server, port } = await serve(
    async () =>
      new Response(
        new ReadableStream({
          pull(controller) {
            if (++pulled > 500) controller.close();
            else controller.enqueue(chunk);
          },
          cancel() {
            cancelled = true;
          },
        }),
        { headers: { "content-type": "application/zip" } },
      ),
  );
  try {
    const first = await new Promise<{ status: number; req: ReturnType<typeof request> }>((resolve) => {
      const req = request({ port, host: "127.0.0.1", path: "/runlight/api/export" }, (res) => {
        res.pause();
        resolve({ status: res.statusCode ?? 0, req });
      });
      req.end();
    });
    assert.equal(first.status, 200, "headers go out before the body is read");
    await wait(300);
    assert.ok(pulled < 100, `a paused client holds the reading back (${pulled} MB read)`);
    first.req.destroy();
    await wait(300);
    assert.ok(cancelled, "a client that leaves cancels the body");
  } finally {
    server.closeAllConnections();
    server.close();
  }
});

test("a body that fails before its first byte is a 500, and one that fails partway cuts the connection", async () => {
  const { server, port } = await serve(async (request) => {
    const partway = new URL(request.url).pathname.endsWith("/partway");
    let sent = false;
    return new Response(
      new ReadableStream({
        pull(controller) {
          if (partway && !sent) return void ((sent = true), controller.enqueue(new TextEncoder().encode("PK")));
          controller.error(new Error("the install went away"));
        },
      }),
      { headers: { "content-type": "application/zip", "content-length": "1000" } },
    );
  });
  try {
    const early = await fetch(`http://127.0.0.1:${port}/runlight/api/export`);
    assert.equal(early.status, 500);
    assert.equal(early.headers.get("content-type"), null, "none of the failed answer's headers are kept");
    await assert.rejects(
      fetch(`http://127.0.0.1:${port}/runlight/api/partway`).then((late) => late.arrayBuffer()),
      "a short body is never taken as the whole answer",
    );
  } finally {
    server.closeAllConnections();
    server.close();
  }
});

test("readJsonCapped reads a body up to its limit and refuses one past it", async () => {
  assert.deepEqual(await readJsonCapped(new Response('{"sites":[]}'), 1024), { sites: [] });
  await assert.rejects(readJsonCapped(new Response("x".repeat(2048)), 1024), BodyTooLong);
  let pulls = 0;
  const endless = new Response(new ReadableStream({ pull: (controller) => void (pulls++, controller.enqueue(new Uint8Array(64 * 1024))) }));
  await assert.rejects(readJsonCapped(endless, 1024 * 1024), BodyTooLong);
  assert.ok(pulls < 40, "an endless body stops being read at the limit");
});
