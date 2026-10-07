import assert from "node:assert/strict";
import { createServer } from "node:net";
import { afterEach, test } from "node:test";
import { runlight } from "../src/index.js";
import { seal, unseal } from "../src/mail/secret.js";
import { signV4 } from "../src/mail/ses.js";
import { mime, smtpSend } from "../src/mail/smtp.js";
import { send } from "../src/mail/transports.js";
import { lastPeriod } from "../src/reports.js";
import { sqlite } from "../src/stores/sqlite.js";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function capture(status = 200) {
  const calls: Array<{ url: string; headers: Record<string, string>; body: string }> = [];
  globalThis.fetch = (async (input: string | URL | Request, init: RequestInit = {}) => {
    calls.push({ url: String(input), headers: Object.fromEntries(Object.entries((init.headers ?? {}) as Record<string, string>)), body: String(init.body ?? "") });
    return new Response(status === 200 ? "{}" : "nope", { status });
  }) as typeof fetch;
  return calls;
}

const message = { to: "jon@example.com", from: "reports@example.com", fromName: "Runlight", subject: "Hello", html: "<p>Hi</p>", text: "Hi", headers: { "List-Unsubscribe": "<https://x/u>" } };

test("sealed keys open only with the same secret", async () => {
  const sealed = await seal('{"apiKey":"re_123"}', "server secret");
  assert.ok(sealed.startsWith("v1:") && !sealed.includes("re_123"));
  assert.equal(await unseal(sealed, "server secret"), '{"apiKey":"re_123"}');
  assert.equal(await unseal(sealed, "another secret"), null);
  assert.equal(await unseal(await seal("x", null), null), "x", "with no secret the value is kept as typed");
});

test("SigV4 matches AWS's published example", async () => {
  // https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html (the IAM ListUsers example)
  const headers = await signV4({
    method: "GET",
    url: new URL("https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08"),
    body: "",
    region: "us-east-1",
    service: "iam",
    accessKeyId: "AKIDEXAMPLE",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    now: new Date("2015-08-30T12:36:00Z"),
    headers: { "content-type": "application/x-www-form-urlencoded; charset=utf-8" },
  });
  assert.equal(
    headers.authorization,
    "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7",
  );
});

test("each service gets the request it documents", async () => {
  let calls = capture();
  await send({ service: "resend", apiKey: "re_1" }, message);
  assert.equal(calls[0]!.url, "https://api.resend.com/emails");
  assert.equal(calls[0]!.headers.authorization, "Bearer re_1");
  assert.deepEqual(JSON.parse(calls[0]!.body).to, ["jon@example.com"]);
  assert.equal(JSON.parse(calls[0]!.body).from, "Runlight <reports@example.com>");

  calls = capture();
  await send({ service: "postmark", serverToken: "pm" }, message);
  assert.equal(calls[0]!.headers["x-postmark-server-token"], "pm");
  assert.equal(JSON.parse(calls[0]!.body).MessageStream, "outbound");

  calls = capture();
  await send({ service: "mailgun", apiKey: "key", domain: "mg.example.com", region: "eu" }, message);
  assert.equal(calls[0]!.url, "https://api.eu.mailgun.net/v3/mg.example.com/messages");
  assert.equal(calls[0]!.headers.authorization, `Basic ${btoa("api:key")}`);
  assert.equal(new URLSearchParams(calls[0]!.body).get("h:List-Unsubscribe"), "<https://x/u>");

  calls = capture();
  await send({ service: "ses", region: "eu-west-1", accessKeyId: "AKID", secretAccessKey: "secret" }, message);
  assert.equal(calls[0]!.url, "https://email.eu-west-1.amazonaws.com/v2/email/outbound-emails");
  assert.match(calls[0]!.headers.authorization!, /^AWS4-HMAC-SHA256 Credential=AKID\/\d{8}\/eu-west-1\/ses\/aws4_request/);

  calls = capture();
  await send({ service: "webhook", url: "https://hooks.example.com/mail", secret: "s" }, message);
  assert.match(calls[0]!.headers["x-runlight-signature"]!, /^sha256=[a-f0-9]{64}$/);

  capture(401);
  await assert.rejects(send({ service: "sendgrid", apiKey: "bad" }, message), /api.sendgrid.com answered 401/);
  await assert.rejects(send({ service: "webhook", url: "http://example.com/x" }, message), /must use https/);
  await assert.rejects(send({ service: "resend" } as never, message), /Enter the api key/);
});

test("SMTP: STARTTLS refused is an error; a plain relay takes the message", async () => {
  const seen: string[] = [];
  let data = "";
  const server = createServer((socket) => {
    let inData = false;
    let buffer = "";
    socket.write("220 test ESMTP\r\n");
    socket.on("data", (chunk) => {
      buffer += chunk.toString();
      let at: number;
      while ((at = buffer.indexOf("\r\n")) >= 0) {
        const line = buffer.slice(0, at);
        buffer = buffer.slice(at + 2);
        if (inData) {
          if (line === ".") {
            inData = false;
            socket.write("250 queued\r\n");
          } else data += `${line}\n`;
          continue;
        }
        seen.push(line.split(" ")[0]!);
        if (line.startsWith("EHLO")) socket.write("250-test\r\n250 AUTH PLAIN\r\n");
        else if (line.startsWith("AUTH PLAIN")) socket.write(Buffer.from(line.slice(11), "base64").toString() === "\0jon\0pw" ? "235 ok\r\n" : "535 no\r\n");
        else if (line === "DATA") {
          inData = true;
          socket.write("354 go\r\n");
        } else if (line === "QUIT") socket.end("221 bye\r\n");
        else socket.write("250 ok\r\n");
      }
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;
  try {
    await assert.rejects(smtpSend({ service: "smtp", host: "127.0.0.1", port: String(port), security: "starttls" }, message, "reports@example.com"), /does not offer STARTTLS/);
    seen.length = 0;
    await smtpSend({ service: "smtp", host: "127.0.0.1", port: String(port), security: "none", username: "jon", password: "pw" }, { ...message, text: ".starts with a dot" }, "Runlight <reports@example.com>");
    assert.deepEqual(seen, ["EHLO", "AUTH", "MAIL", "RCPT", "DATA", "QUIT"]);
    assert.match(data, /Subject: Hello/);
    assert.match(data, /List-Unsubscribe: <https:\/\/x\/u>/);
    assert.match(data, /multipart\/alternative/);
  } finally {
    server.close();
  }
  const raw = mime({ ...message, subject: "Café report" }, "Runlight <reports@example.com>");
  assert.match(raw, /Subject: =\?UTF-8\?B\?/);
});

test("report periods: last Monday to Sunday, or last month, due from 8am the day after, in the site's zone", () => {
  // Wednesday 8 October 2026, 15:00 UTC (11:00 in Toronto).
  const now = Date.UTC(2026, 9, 8, 15);
  const week = lastPeriod("weekly", now, "America/Toronto");
  assert.deepEqual([week.key, week.fromDate, week.toDate, week.previousFrom], ["w:2026-09-28", "2026-09-28", "2026-10-04", "2026-09-21"]);
  assert.equal(week.dueAt, Date.UTC(2026, 9, 5, 12), "Monday 5 October, 8am Toronto");
  const month = lastPeriod("monthly", now, "America/Toronto");
  assert.deepEqual([month.key, month.fromDate, month.toDate, month.previousFrom, month.previousTo], ["m:2026-09", "2026-09-01", "2026-09-30", "2026-08-01", "2026-08-31"]);
  // Monday at 3am local: last week is over but not yet due.
  const early = lastPeriod("weekly", Date.UTC(2026, 9, 5, 7), "America/Toronto");
  assert.ok(Date.UTC(2026, 9, 5, 7) < early.dueAt);
});

test("reports go out once per period, retry after a failure, and keep keys from the browser", async () => {
  let now = Date.UTC(2026, 9, 8, 15);
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { name: "Example", hostnames: ["example.com"], timezone: "America/Toronto" }, secret: "s3cret", now: () => now });
  const { GET, PUT, POST } = rl.routes({ token: "t" });
  const auth = { authorization: "Bearer t", "content-type": "application/json" };
  const call = (method: string, path: string, body?: unknown) =>
    (method === "GET" ? GET : method === "PUT" ? PUT : POST)(new Request(`https://stats.example.com/runlight${path}`, { method, headers: auth, body: body === undefined ? undefined : JSON.stringify(body) }));

  assert.equal((await call("PUT", "/api/mail", { service: "resend", apiKey: "re_live_key", from: "not an address" })).status, 400);
  assert.equal((await call("PUT", "/api/mail", { service: "resend", apiKey: "re_live_key", from: "reports@example.com", fromName: "Runlight" })).status, 200);
  const shown = await (await call("GET", "/api/mail")).text();
  assert.ok(!shown.includes("re_live_key"), "the key never goes back to the browser");
  assert.deepEqual(JSON.parse(shown).saved, ["apiKey"]);
  const stored = (await rl.store.setting("mail"))!;
  assert.ok(stored.startsWith("v1:") && !stored.includes("re_live_key"), "and is encrypted at rest");
  // Saving again with the key left blank keeps it.
  await call("PUT", "/api/mail", { service: "resend", apiKey: "", from: "reports@example.com" });
  assert.equal((await rl.mailSettings())!.apiKey, "re_live_key");

  const made = await call("POST", "/api/reports", { email: "Jon@Example.com", frequency: "weekly", lang: "fr", origin: "https://stats.example.com/runlight" });
  assert.equal(made.status, 201);
  assert.equal((await call("POST", "/api/reports", { email: "jon@example.com", frequency: "weekly" })).status, 400, "no duplicates");

  let calls = capture(500);
  assert.deepEqual(await rl.sendReports(), { sent: 0, failed: 1 });
  calls = capture();
  assert.deepEqual(await rl.sendReports(), { sent: 1, failed: 0 }, "a failed send is tried again");
  const body = JSON.parse(calls[0]!.body);
  assert.equal(body.to[0], "jon@example.com");
  assert.match(body.subject, /^Example : 0 personne la semaine dernière$/);
  assert.match(body.html, /du 28 sept\. au 4 oct\. 2026/);
  const unsubscribe = /<(https:\/\/stats\.example\.com\/runlight\/unsubscribe\/[a-f0-9]{32})>/.exec(body.headers["List-Unsubscribe"])![1]!;
  assert.equal(body.headers["List-Unsubscribe-Post"], "List-Unsubscribe=One-Click");
  assert.deepEqual(await rl.sendReports(), { sent: 0, failed: 0 }, "the same period never goes twice");
  now += 7 * 86_400_000;
  capture();
  assert.deepEqual(await rl.sendReports(), { sent: 1, failed: 0 }, "the next week does");

  // Opening the unsubscribe link changes nothing; the button does.
  const page = await GET(new Request(unsubscribe));
  assert.match(await page.text(), /<form method="post">/);
  assert.equal((await rl.store.reports()).length, 1);
  const done = await POST(new Request(unsubscribe, { method: "POST", body: "List-Unsubscribe=One-Click", headers: { "content-type": "application/x-www-form-urlencoded" } }));
  assert.equal(done.status, 200);
  assert.equal((await rl.store.reports()).length, 0);
  assert.equal((await GET(new Request(unsubscribe))).status, 404);
});

test("the server has every language, English included", async () => {
  const { languages, translator } = await import("../src/messages.js");
  assert.deepEqual(languages().sort(), ["de", "en", "es", "fr", "pt"]);
  assert.equal(translator("en").t("email.open"), "Open the dashboard");
  assert.equal(translator("xx").t("email.open"), "Open the dashboard", "an unknown language falls back to English");
  assert.equal(translator("de").tn("headline.who", 1, { n: "1" }), "1 Person");
});
