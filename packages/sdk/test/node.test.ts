import assert from "node:assert/strict";
import { createServer, request } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { BodyTooLong, readJsonCapped } from "../src/body.js";
import { shortLinks, toNodeHandler } from "../src/node.js";
import { CHROME_MAC, setup } from "./helpers.js";

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

test("the Node adapter's requests carry a signal that fires when the client leaves", async () => {
  let aborted = false;
  let finished = false;
  const { server, port } = await serve(async (request) => {
    if (new URL(request.url).pathname.endsWith("/quick")) {
      request.signal.addEventListener("abort", () => (finished = true));
      return new Response("{}");
    }
    await new Promise((resolve) => request.signal.addEventListener("abort", resolve));
    aborted = request.signal.aborted;
    return new Response("{}");
  });
  try {
    const req = request({ port, host: "127.0.0.1", path: "/runlight/api/stats" });
    req.on("error", () => {});
    req.end();
    await wait(200);
    req.destroy();
    await wait(300);
    assert.ok(aborted, "request.signal fired");
    const quick = await fetch(`http://127.0.0.1:${port}/runlight/api/quick`);
    assert.equal(await quick.text(), "{}");
    await wait(100);
    assert.equal(finished, false, "a finished response never fires the signal");
  } finally {
    server.closeAllConnections();
    server.close();
  }
});

test("the Node adapter closes the connection after a 413, and the next request works", async () => {
  const { server, port } = await serve(async () => new Response("{}", { headers: { "content-type": "application/json" } }));
  try {
    const big = await fetch(`http://127.0.0.1:${port}/runlight/api/links/import`, { method: "POST", body: "x".repeat(11 * 1024 * 1024) });
    assert.equal(big.status, 413);
    assert.equal(big.headers.get("connection"), "close");
    for (let i = 0; i < 8; i++) assert.equal((await fetch(`http://127.0.0.1:${port}/runlight/api/sites`)).status, 200);
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

/** A request with its own Host header, which fetch does not allow. */
function callAt(port: number, host: string, path: string, method = "GET", body?: string) {
  return new Promise<{ status: number; location?: string; text: string }>((resolve, reject) => {
    const req = request({ port, host: "127.0.0.1", path, method, headers: { host, "user-agent": CHROME_MAC } }, (res) => {
      let text = "";
      res.on("data", (chunk) => (text += chunk));
      res.on("end", () => resolve({ status: res.statusCode ?? 0, location: res.headers.location, text }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

test("shortLinks answers link domains and the app's link path before the app, and passes the rest on with its body", async () => {
  const t = setup("sqlite");
  const json = (body: unknown) => ({ method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json", authorization: "Bearer secret" } });
  assert.equal((await t.routes.POST(new Request("https://example.com/runlight/api/link-domains", json({ domain: "t.example.com" })))).status, 201);
  await t.routes.POST(new Request("https://example.com/runlight/api/links", json({ url: "https://example.org/a", slug: "a", domain: "t.example.com" })));
  const links = shortLinks(t.rl);
  const runlightRoutes = toNodeHandler(t.routes.handler);
  const reached: string[] = [];
  // As Express runs them: shortLinks, then the routes, then the app.
  const server = createServer((req, res) => {
    void links(req, res, (error) => {
      if (error) throw error;
      void runlightRoutes(req, res, async () => {
        let body = "";
        for await (const chunk of req) body += chunk;
        reached.push(`${req.headers.host} ${req.method} ${req.url} ${body}`);
        res.end("app");
      });
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  const call = (host: string, path: string, method = "GET", body?: string) => callAt(port, host, path, method, body);
  try {
    const redirected = await call("t.example.com", "/a");
    assert.equal(redirected.status, 302, "a link-domain request is redirected");
    assert.equal(redirected.location, "https://example.org/a");
    assert.equal((await call("t.example.com", "/missing")).status, 404, "a link domain answers every path itself");
    assert.equal((await call("t.example.com", "/runlight/api/sites")).status, 401, "the dashboard's paths still reach Runlight on a link domain");
    assert.equal((await call("example.com", "/go/a")).location, "https://example.org/a", "the app's link path answers on its own host");
    assert.deepEqual(reached, []);
    assert.equal((await call("example.com", "/a")).text, "app", "the app's own host reaches the app");
    assert.equal((await call("example.com", "/go/missing")).text, "app", "a slug with no link is the app's to answer");
    assert.equal((await call("example.com", "/go/%E0%A4%A")).text, "app", "so is one that is not valid percent-encoding");
    assert.equal((await call("example.com", "/form", "POST", "name=x")).text, "app");
    assert.deepEqual(reached, ["example.com GET /a ", "example.com GET /go/missing ", "example.com GET /go/%E0%A4%A ", "example.com POST /form name=x"]);
  } finally {
    server.close();
  }
});

test("shortLinks without next says whether it answered", async () => {
  const t = setup("sqlite");
  const json = (body: unknown) => ({ method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json", authorization: "Bearer secret" } });
  await t.routes.POST(new Request("https://example.com/runlight/api/link-domains", json({ domain: "t.example.com" })));
  const links = shortLinks(t.rl);
  const server = createServer(async (req, res) => {
    if (await links(req, res)) return;
    res.end("app");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  try {
    const check = await callAt(port, "t.example.com", "/.well-known/runlight-link-domain");
    assert.deepEqual(JSON.parse(check.text), { runlight: true, domain: "t.example.com" });
    assert.equal((await callAt(port, "example.com", "/")).text, "app");
  } finally {
    server.close();
  }
});
