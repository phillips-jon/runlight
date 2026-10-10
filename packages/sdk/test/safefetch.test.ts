import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { PrivateAddressError, installAddress, installFetch, publicAddress, publicFetch, resolvesPrivately } from "../src/safefetch.js";

test("only addresses on the public internet count as public", () => {
  for (const ip of ["93.184.215.14", "1.1.1.1", "2606:4700:4700::1111", "2a00:1450:4001:82a::200e"]) assert.equal(publicAddress(ip), true, ip);
  for (const ip of [
    "127.0.0.1", "10.0.0.1", "172.16.5.4", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
    "::1", "::", "fe80::1", "fd00::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:7f00:1", "::ffff:169.254.169.254", "64:ff9b::a00:1",
    "2002:a00:1::", "2001:db8::1", "2001:0:4136:e378::1", "[::1]", "not an address", "1.2.3", "1.2.3.256",
  ]) assert.equal(publicAddress(ip), false, ip);
});

test("a public fetch never reaches the install's own network, however the address is written", async () => {
  // Something listening locally, which none of these may reach.
  let reached = 0;
  const inside = createServer((_, res) => {
    reached++;
    res.end("secret");
  });
  await new Promise<void>((resolve) => inside.listen(0, "127.0.0.1", resolve));
  const port = (inside.address() as { port: number }).port;
  try {
    for (const url of [`http://127.0.0.1:${port}/`, `https://127.0.0.1:${port}/`, `https://[::1]:${port}/`, `https://[::ffff:127.0.0.1]:${port}/`, `https://localhost:${port}/`]) {
      await assert.rejects(publicFetch(url, { timeoutMs: 2000 }), PrivateAddressError, url);
    }
    assert.equal(reached, 0);
    assert.equal(await resolvesPrivately("localhost"), true);
    assert.equal(await resolvesPrivately("name.that.does.not.resolve.invalid"), false);
  } finally {
    inside.close();
  }
});

test("a fetch that sends something follows no redirect, and says what it asked", async () => {
  const asked: Array<{ url: string; method: string; body: string }> = [];
  const fetch = (async (input: string | URL | Request, init: RequestInit = {}) => {
    asked.push({ url: String(input), method: String(init.method), body: String(init.body) });
    return new Response(null, { status: 307, headers: { location: "https://93.184.215.15/elsewhere" } });
  }) as typeof globalThis.fetch;
  const answer = await publicFetch("https://93.184.215.14/token", { timeoutMs: 2000, method: "POST", body: "code=1", redirects: 3, fetch });
  assert.equal(answer.status, 307, "the redirect comes back as it is");
  assert.deepEqual(asked, [{ url: "https://93.184.215.14/token", method: "POST", body: "code=1" }]);
});

test("another install is only fetched at a public https address, with no redirect followed", async () => {
  let reached = 0;
  const inside = createServer((_, res) => {
    reached++;
    res.writeHead(302, { location: "http://169.254.169.254/" }).end();
  });
  await new Promise<void>((resolve) => inside.listen(0, "127.0.0.1", resolve));
  const port = (inside.address() as { port: number }).port;
  try {
    for (const url of ["https://example.com/runlight", "https://example.com"]) assert.equal(installAddress(url, false), true, url);
    for (const url of [`http://127.0.0.1:${port}/runlight`, "http://localhost", "http://example.com", "ftp://example.com"]) assert.equal(installAddress(url, false), false, url);
    // Only code allows an install on this machine, and then only at these two names.
    for (const url of [`http://127.0.0.1:${port}/runlight`, "http://localhost", "http://localhost:3000/runlight"]) assert.equal(installAddress(url, true), true, url);
    for (const url of ["http://10.0.0.1", "http://localhost.example.com", "http://localhost@example.com", "http://127.0.0.1:80@example.com"]) assert.equal(installAddress(url, true), false, url);

    for (const url of [`http://127.0.0.1:${port}/api/sites`, `https://127.0.0.1:${port}/api/sites`, `https://localhost:${port}/api/sites`, "https://169.254.169.254/latest/meta-data/"]) {
      await assert.rejects(installFetch(url, { timeoutMs: 2000, local: false }), PrivateAddressError, url);
    }
    assert.equal(reached, 0, "nothing on this machine was asked");
    // Allowed in code, a local install is asked, and its redirect is handed back, not followed.
    const answer = await installFetch(`http://127.0.0.1:${port}/api/sites`, { timeoutMs: 2000, local: true });
    assert.equal(answer.status, 302);
    assert.equal(reached, 1);
  } finally {
    inside.close();
  }
});
