// Runs the TypeScript SDK's mail services, SigV4 signing, MIME, SMTP client, address checks, icon link
// picking, and link importers against recording fakes, and writes what they send and return to
// packages/php/tests/fixtures/outbound.json, so the PHP port's tests can require the very same requests.
// Run with: TZ=UTC node --import tsx scripts/php-fixtures-outbound.mts
import { writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { mock } from "node:test";
import { iconLinks } from "../packages/sdk/src/icon.ts";
import { bitly } from "../packages/sdk/src/importers/bitly.ts";
import { dub } from "../packages/sdk/src/importers/dub.ts";
import { rebrandly } from "../packages/sdk/src/importers/rebrandly.ts";
import { shortio } from "../packages/sdk/src/importers/shortio.ts";
import type { Importer } from "../packages/sdk/src/importers/types.ts";
import { umami } from "../packages/sdk/src/importers/umami.ts";
import { seal } from "../packages/sdk/src/mail/secret.ts";
import { signV4 } from "../packages/sdk/src/mail/ses.ts";
import { mime, smtpSend } from "../packages/sdk/src/mail/smtp.ts";
import { send, serviceMessage } from "../packages/sdk/src/mail/transports.ts";
import { publicAddress } from "../packages/sdk/src/safefetch.ts";

if (process.env.TZ !== "UTC") throw new Error("Run with TZ=UTC, as the PHP tests run");

const NOW = Date.UTC(2026, 9, 8, 15, 4, 5, 678);
mock.timers.enable({ apis: ["Date"], now: NOW });
let uuids = 0;
const uuid = () => `00000000-0000-4000-8000-${String(++uuids).padStart(12, "0")}`;
crypto.randomUUID = uuid as never;

type Recorded = { method: string; url: string; headers: Record<string, string>; body: string };
const record = (input: string | URL | Request, init: RequestInit = {}): Recorded => ({
  method: init.method ?? "GET",
  url: String(input),
  headers: Object.fromEntries(new Headers(init.headers as HeadersInit)),
  body: init.body === undefined || init.body === null ? "" : String(init.body),
});
const failure = (error: unknown) => {
  const e = error as Error & { code?: unknown; params?: unknown; status?: unknown };
  return { message: e.message, ...(typeof e.code === "string" ? { code: e.code } : {}), ...(e.params ? { params: e.params } : {}), ...(typeof e.status === "number" ? { status: e.status } : {}) };
};

// Mail: every service, with and without a name and headers, and the ways a send fails.
const message = { to: "jon@example.com", from: "reports@example.com", fromName: "Runlight", subject: "Hello", html: "<p>Hi</p>", text: "Hi", headers: { "List-Unsubscribe": "<https://x/u>", "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" } };
const plain = { to: "jon@example.com", from: "reports@example.com", subject: "Café \u{1F600} / \"quoted\"", html: "<p>é</p>", text: "line\nnext" };
const quirky = { ...message, fromName: "Jon \"The\" O'Brien\\\r\n", headers: {} };
const services = [
  { service: "ses", region: "eu-west-1", accessKeyId: " AKID ", secretAccessKey: "secret" },
  { service: "resend", apiKey: "re_1" },
  { service: "postmark", serverToken: "pm" },
  { service: "postmark", serverToken: "pm", stream: "broadcast" },
  { service: "sendgrid", apiKey: "SG.1" },
  { service: "mailgun", apiKey: "key", domain: "mg.example.com", region: "eu" },
  { service: "mailgun", apiKey: "kéy", domain: "mg ex/ample.com", region: "us" },
  { service: "brevo", apiKey: "xkeysib-1" },
  { service: "mailjet", apiKey: "mj", secretKey: "mjs" },
  { service: "mailersend", apiKey: "mlsn.1" },
  { service: "sparkpost", apiKey: "sp", region: "eu" },
  { service: "sparkpost", apiKey: "sp", region: "us" },
  { service: "webhook", url: "https://hooks.example.com/mail", secret: "s" },
  { service: "webhook", url: "http://localhost:8080/mail" },
];
const answers: Array<{ status: number; body: string } | "unreachable"> = [{ status: 200, body: "{}" }];
const mailCases: unknown[] = [];
const realFetch = globalThis.fetch;
async function mailCase(config: Record<string, string>, m: object, answer: { status: number; body: string } | "unreachable") {
  const requests: Recorded[] = [];
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    requests.push(record(input, init));
    if (answer === "unreachable") throw new TypeError("fetch failed");
    return new Response(answer.body, { status: answer.status });
  }) as typeof fetch;
  let error: unknown = null;
  try {
    await send(config as never, m as never);
  } catch (e) {
    error = failure(e);
  }
  mailCases.push({ config, message: m, answer, requests, error });
}
for (const config of services) {
  for (const m of [message, plain, quirky]) for (const answer of answers) await mailCase(config, m, answer);
}
for (const [config, answer] of [
  [{ service: "sendgrid", apiKey: "bad" }, { status: 401, body: "nope" }],
  [{ service: "postmark", serverToken: "pm" }, { status: 422, body: '{"ErrorCode":300,"Message":"Invalid \'To\' address"}' }],
  [{ service: "resend", apiKey: "re" }, { status: 500, body: '{"errors":[{"message":"down for now"}]}' }],
  [{ service: "ses", region: "us-east-1", accessKeyId: "A", secretAccessKey: "B" }, { status: 400, body: "<ErrorResponse><Error><Message> Email address is not verified. </Message></Error></ErrorResponse>" }],
  [{ service: "ses", region: "us-east-1", accessKeyId: "A", secretAccessKey: "B" }, "unreachable"],
  [{ service: "webhook", url: "https://hooks.example.com/mail" }, { status: 500, body: '{"message":"secret page"}' }],
  [{ service: "mailgun", apiKey: "k", domain: "d", region: "us" }, "unreachable"],
  [{ service: "brevo", apiKey: "b" }, { status: 400, body: `{"message":"${"x".repeat(250)}"}` }],
  [{ service: "ses", region: "nowhere", accessKeyId: "A", secretAccessKey: "B" }, answers[0]],
  [{ service: "webhook", url: "http://example.com/x" }, answers[0]],
  [{ service: "resend" }, answers[0]],
  [{ service: "resend", apiKey: "   " }, answers[0]],
  [{ service: "mailgun", apiKey: "k", domain: "d", region: "asia" }, answers[0]],
  [{ service: "pigeon" }, answers[0]],
] as const) {
  await mailCase(config as Record<string, string>, message, answer as never);
}
globalThis.fetch = realFetch;

const replies = [
  '{"message":"a"}', '{"Message":"b"}', '{"error":"c"}', '{"error":{"message":"d"}}', '{"errors":[{"message":"e"}]}', '{"errors":["f"]}',
  '{"ErrorMessage":"g"}', '{"message":"","error":"h"}', '{"message":5}', "[1,2]", "null", '"text"', "<html>page</html>",
  "<Error><Message>  spaced  </Message></Error>", `<Message>${"y".repeat(201)}</Message>`, "", "not json", '{"message":"café"}',
];

const signatures = [];
for (const input of [
  { method: "GET", url: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08", body: "", region: "us-east-1", service: "iam", accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", now: Date.UTC(2015, 7, 30, 12, 36), headers: { "content-type": "application/x-www-form-urlencoded; charset=utf-8" } },
  { method: "POST", url: "https://example.amazonaws.com/a b/%7Ec/café?z=1&b=2+3&a=x%20y&a=0&c", body: '{"x":1}', region: "eu-west-1", service: "ses", accessKeyId: "K", secretAccessKey: "S", now: NOW, headers: { "Content-Type": "  application/json   with   spaces ", "X-Extra": "v" } },
]) {
  signatures.push({ input, headers: await signV4({ ...input, url: new URL(input.url), now: new Date(input.now) }) });
}

const mimes = [];
for (const [m, from] of [
  [message, "Runlight <reports@example.com>"],
  [{ ...plain, text: ".starts with a dot\r\n.and another", html: "<p>" + "long ".repeat(40) + "</p>" }, "reports@example.com"],
  [{ ...message, subject: "Café report", fromName: "Jön" }, "Jön <reports@example.com>"],
  [{ ...message, from: "nobody", text: "", html: "" }, "nobody"],
] as const) {
  uuids = 0;
  mimes.push({ message: m, from, now: NOW, mime: mime(m as never, from, new Date(NOW)) });
}

// SMTP: the bytes the client sends a plain relay that takes the message, and what refuses STARTTLS says.
async function smtpConversation(config: Record<string, string>, m: object, from: string) {
  let received = "";
  const server = createServer((socket) => {
    let inData = false;
    let buffer = "";
    socket.write("220 test ESMTP\r\n");
    socket.on("data", (chunk) => {
      received += chunk.toString("utf8");
      buffer += chunk.toString("utf8");
      let at: number;
      while ((at = buffer.indexOf("\r\n")) >= 0) {
        const line = buffer.slice(0, at);
        buffer = buffer.slice(at + 2);
        if (inData) {
          if (line === ".") {
            inData = false;
            socket.write("250 queued\r\n");
          }
          continue;
        }
        if (line.startsWith("EHLO")) socket.write("250-test\r\n250-SIZE 1000\r\n250 AUTH PLAIN\r\n");
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
  uuids = 0;
  let error: unknown = null;
  try {
    await smtpSend({ service: "smtp", host: "127.0.0.1", port: String(port), ...config } as never, m as never, from);
  } catch (e) {
    error = failure(e);
  }
  server.close();
  return { config, message: m, from, received, error };
}
const smtp = [
  await smtpConversation({ security: "none", username: "jon", password: "pw" }, { ...message, text: ".starts with a dot" }, "Runlight <reports@example.com>"),
  await smtpConversation({ security: "none" }, plain, "reports@example.com"),
  await smtpConversation({ security: "none", username: "jon", password: "wrong" }, message, "reports@example.com"),
  await smtpConversation({ security: "starttls" }, message, "reports@example.com"),
];

const sealed = [];
for (const [value, secret] of [['{"apiKey":"re_123"}', "server secret"], ["café \u{1F600}", "s"], ["", "s"], ["x".repeat(1000), "long"]] as const) {
  sealed.push({ value, secret, sealed: await seal(value, secret) });
}

const ips = [
  "93.184.215.14", "1.1.1.1", "2606:4700:4700::1111", "2a00:1450:4001:82a::200e", "8.8.8.8", "100.63.255.255", "100.128.0.0", "172.15.0.1", "172.32.0.1", "192.0.1.1",
  "198.17.0.1", "198.20.0.1", "223.255.255.255", "::ffff:8.8.8.8", "64:ff9b::808:808", "2002:808:808::", "2001:4860::1", "fec0::1", "::2", "::0.0.0.2",
  "127.0.0.1", "10.0.0.1", "172.16.5.4", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "192.0.0.1", "192.0.2.1",
  "198.18.0.1", "198.51.100.1", "203.0.113.1", "::1", "::", "fe80::1", "fd00::1", "fc00::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:7f00:1",
  "::ffff:169.254.169.254", "64:ff9b::a00:1", "2002:a00:1::", "2001:db8::1", "2001:0:4136:e378::1", "100::1", "[::1]", "[2606:4700::1]", "fe80::1%eth0",
  "not an address", "1.2.3", "1.2.3.256", "01.02.03.04", "1.2.3.4.5", "1::2::3", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7::", "::1.2.3", "::ffff:1.2.3.999", "", "g::1",
  "2606:4700:4700:0000:0000:0000:0000:1111", "::FFFF:7F00:1", "1:2:3:4:5:6:1.2.3.4",
].map((ip) => ({ ip, public: publicAddress(ip) }));

const pages = [
  { html: '<head><link rel="icon" href="/favicon.png" type="image/png"><link rel="apple-touch-icon" href="https://cdn.example.com/touch.png"><link rel="icon" href="/i.svg"><LINK REL="Shortcut Icon" HREF=\'/old.ico\'></head>', base: "https://example.com" },
  { html: '<link rel=icon href=//other.example.com/x.ico><link rel="stylesheet" href="/s.css"><link rel="icon" href="http://insecure.example.com/i.png"><link rel="icon" href=""><link href="/late.png" rel="icon">', base: "https://example.com/blog/" },
  { html: '<link rel="icon" type="image/svg+xml" href="icon">\n<link rel="mask-icon icon" href="../m.png" >', base: "https://example.com/a/b/" },
];
const icons = pages.map((p) => ({ ...p, links: iconLinks(p.html, p.base) }));

// Importers: each runs to the end of its cursor against a table of answers, as importers.test.ts serves them.
type Route = { pattern: string; status?: number; body?: unknown; headers?: Record<string, string>; times?: number; unreachable?: boolean };
type Scenario = { name: string; source: string; credentials: Record<string, string>; routes: Route[]; known?: string[]; cursor?: string };
const IMPORTERS: Record<string, Importer> = { umami, dub, bitly, shortio, rebrandly };
const dubLinks = [
  { id: "l1", domain: "dub.sh", key: "launch", url: "https://a.com/launch", title: "Launch", createdAt: "2026-01-02T00:00:00Z" },
  { id: "l2", domain: "go.brand.com", key: "sale", url: "https://a.com/sale", title: null, createdAt: "2026-02-03T00:00:00Z" },
];
const scenarios: Scenario[] = [
  { name: "dub events", source: "dub", credentials: { apiKey: " dub_test " }, routes: [
    { pattern: "api\\.dub\\.co\\/links\\?.*startingAfter=l2", body: [] },
    { pattern: "api\\.dub\\.co\\/links\\?", body: dubLinks },
    { pattern: "\\/events\\?.*linkId=l1", body: [
      { timestamp: "2026-03-01T10:00:00Z", click: { id: "c1", country: "CA", city: "Toronto", device: "Mobile", browser: "Chrome", os: "iOS", referer: "instagram.com", refererUrl: "https://instagram.com/" } },
      { timestamp: "2026-03-02T10:00:00Z", click: { id: "c2", country: "US", device: "Desktop", browser: "Safari", os: "Mac OS", referer: "(direct)" } },
      { timestamp: "2026-03-03T10:00:00.5+02:00", click: { id: "c3", country: null, referer: "news.ycombinator.com", region: "CA-ON" } },
      { timestamp: "bad", click: null },
      { timestamp: "2026-03-04" },
    ] },
    { pattern: "\\/events\\?.*linkId=l2", body: [] },
  ] },
  { name: "dub full page", source: "dub", credentials: { apiKey: "k" }, routes: [
    { pattern: "startingAfter=l9", body: [] },
    { pattern: "api\\.dub\\.co\\/links\\?", body: Array.from({ length: 10 }, (_, i) => ({ ...dubLinks[0], id: `l${i}`, key: `k${i}`, createdAt: i === 3 ? "nope" : dubLinks[0]!.createdAt })) },
    { pattern: "\\/events\\?", body: [] },
  ], known: ["l4", "k5 https://a.com/launch"] },
  { name: "dub daily", source: "dub", credentials: { apiKey: "dub_test" }, routes: [
    { pattern: "api\\.dub\\.co\\/links\\?", body: [{ id: "l1", domain: "dub.sh", key: "x", url: "https://a.com", title: "X", createdAt: "2026-01-02T00:00:00Z" }, { id: "l 2", domain: "dub.sh", key: "y", url: "https://a.com/y", title: "", createdAt: "2026-01-03T00:00:00Z" }] },
    { pattern: "\\/events\\?", status: 403, body: { error: { message: "Business plan required" } } },
    { pattern: "\\/analytics\\?", body: [{ start: "2026-03-01T00:00:00.000Z", clicks: 3 }, { start: "2026-03-02T00:00:00.000Z", clicks: 0 }] },
  ] },
  { name: "dub none", source: "dub", credentials: { apiKey: "dub_test" }, routes: [
    { pattern: "api\\.dub\\.co\\/links\\?", body: [{ id: "l1", domain: "dub.sh", key: "x", url: "https://a.com", title: "X", createdAt: "2026-01-02T00:00:00Z" }] },
    { pattern: "\\/events\\?", status: 403, body: {} },
    { pattern: "\\/analytics\\?", status: 402, body: {} },
  ] },
  { name: "dub refused", source: "dub", credentials: { apiKey: "dub_test" }, routes: [
    { pattern: "api\\.dub\\.co\\/links\\?", body: dubLinks },
    { pattern: "\\/events\\?", status: 401, body: {} },
  ] },
  { name: "dub cursor", source: "dub", credentials: { apiKey: "k" }, cursor: '{"after":"l&1","history":"none"}', routes: [{ pattern: "links\\?", body: dubLinks }] },
  { name: "dub no key", source: "dub", credentials: { apiKey: "  " }, routes: [] },
  { name: "bitly", source: "bitly", credentials: { token: "bitly_test" }, routes: [
    { pattern: "\\/v4\\/groups$", body: { groups: [{ guid: "G1" }, { guid: "G2" }] } },
    { pattern: "\\/groups\\/G1\\/bitlinks", body: { links: [
      { id: "bit.ly/3abc", link: "https://bit.ly/3abc", long_url: "https://a.com/1", title: "One", created_at: "2026-01-01T00:00:00+0000", custom_bitlinks: ["https://t.brand.com/one/"] },
      { id: "bit.ly/gone", link: "https://bit.ly/gone", long_url: "https://a.com/x", title: "Gone", created_at: "2026-01-01T00:00:00+0000", is_deleted: true },
    ], pagination: { search_after: "" } } },
    { pattern: "\\/groups\\/G2\\/bitlinks", body: { links: [{ id: "bit.ly/4def", link: "https://bit.ly/4def", long_url: "https://a.com/2", title: null, created_at: "2026-02-01T00:00:00+0000" }], pagination: {} } },
    { pattern: "\\/bitlinks\\/bit\\.ly%2F3abc\\/clicks", body: { link_clicks: [{ clicks: 5, date: "2026-03-01T00:00:00+0000" }, { clicks: 2, date: "2026-03-02T00:00:00+0000" }, { clicks: 0, date: "2026-03-03T00:00:00+0000" }] } },
    { pattern: "\\/bitlinks\\/bit\\.ly%2F4def\\/clicks", status: 402, body: { message: "UPGRADE_REQUIRED" } },
  ] },
  { name: "bitly paged", source: "bitly", credentials: { apiKey: "b" }, routes: [
    { pattern: "\\/v4\\/groups$", body: { groups: [{ guid: "G1" }] } },
    { pattern: "search_after=next%2Fpage", body: { links: [], pagination: {} } },
    { pattern: "\\/groups\\/G1\\/bitlinks", body: { links: Array.from({ length: 20 }, (_, i) => ({ id: `bit.ly/${i}`, link: "", long_url: `https://a.com/${i}`, title: `T${i}`, created_at: "2026-01-01T00:00:00Z" })), pagination: { search_after: "next/page" } } },
    { pattern: "\\/clicks", body: { link_clicks: [] } },
  ], known: ["bit.ly/3", "7 https://a.com/7"] },
  { name: "bitly refused", source: "bitly", credentials: { token: "t" }, routes: [{ pattern: "\\/v4\\/groups$", status: 401, body: {} }] },
  { name: "bitly no token", source: "bitly", credentials: {}, routes: [] },
  { name: "shortio", source: "shortio", credentials: { apiKey: "sk_test" }, routes: [
    { pattern: "api\\.short\\.io\\/api\\/domains", body: [{ id: 7, hostname: "s.brand.com", extra: 1 }, { id: 8, hostname: "t.brand.com" }] },
    { pattern: "api\\/links\\?.*pageToken=P2", body: { links: [{ idString: "lnk2", id: 2, path: "two", originalURL: "https://a.com/2", createdAt: "2026-02-01T00:00:00Z" }], nextPageToken: null } },
    { pattern: "api\\/links\\?domain_id=7", body: { links: [{ idString: "lnk1", id: 1, path: "one", originalURL: "https://a.com/1", title: "One", createdAt: "2026-01-01T00:00:00Z" }], nextPageToken: "P2" } },
    { pattern: "api\\/links\\?domain_id=8", body: { links: [{ id: 33, path: "three", originalURL: "https://a.com/3", createdAt: "2026-01-01T00:00:00Z" }, { id: 34, path: "four", originalURL: "https://a.com/4", createdAt: "2026-01-01T00:00:00Z" }] } },
    { pattern: "statistics\\/link\\/lnk1\\/by_interval", body: { clickStatistics: [{ x: "2026-03-01T00:00:00Z", y: 4 }, { x: "2026-03-02T00:00:00Z", y: 0 }] } },
    { pattern: "statistics\\/link\\/lnk2\\/by_interval", body: { clickStatistics: { datasets: [{ data: [{ x: Date.UTC(2026, 2, 2), y: 1 }] }] } } },
    { pattern: "statistics\\/link\\/33\\/by_interval", status: 429, headers: { "retry-after": "2" }, body: {}, times: 1 },
    { pattern: "statistics\\/link\\/33\\/by_interval", body: { clickStatistics: {} } },
    { pattern: "statistics\\/link\\/34\\/by_interval", status: 503, body: {} },
  ], known: [] },
  { name: "shortio no key", source: "shortio", credentials: {}, routes: [] },
  { name: "rebrandly", source: "rebrandly", credentials: { apiKey: "rb_test", workspace: " ws1 " }, routes: [
    { pattern: "\\/links\\?.*last=r24", body: Array.from({ length: 3 }, (_, i) => ({ id: `r${25 + i}`, slashtag: `s${25 + i}`, destination: `https://a.com/${25 + i}`, domain: { fullName: "rebrand.ly" }, createdAt: "2026-01-01T00:00:00Z" })) },
    { pattern: "rebrandly\\.com\\/v1\\/links\\?", body: Array.from({ length: 25 }, (_, i) => ({ id: `r${i}`, title: i === 1 ? "Titled" : null, slashtag: `s${i}`, destination: `https://a.com/${i}`, ...(i === 2 ? {} : { domain: i === 3 ? {} : { fullName: "rebrand.ly" } }), createdAt: "2026-01-01T00:00:00Z" })) },
  ] },
  { name: "rebrandly retries", source: "rebrandly", credentials: { apiKey: "rb" }, routes: [
    { pattern: "links", status: 429, headers: { "retry-after": "1.5" }, body: {}, times: 1 },
    { pattern: "links", status: 500, headers: { "retry-after": "soon" }, body: {}, times: 1 },
    { pattern: "links", status: 502, headers: { "retry-after": "60" }, body: {}, times: 1 },
    { pattern: "links", body: [] },
  ] },
  { name: "rebrandly gives up", source: "rebrandly", credentials: { apiKey: "rb" }, routes: [{ pattern: "links", status: 500, body: {} }] },
  { name: "rebrandly unreachable", source: "rebrandly", credentials: { apiKey: "rb" }, routes: [{ pattern: "links", unreachable: true }] },
  { name: "rebrandly unreachable twice", source: "rebrandly", credentials: { apiKey: "rb" }, routes: [{ pattern: "links", unreachable: true, times: 2 }, { pattern: "links", status: 404, body: {} }] },
  { name: "umami sign-in", source: "umami", credentials: { url: " https://stats.example.com// ", username: "jon", password: "pw" }, routes: [
    { pattern: "\\/api\\/auth\\/login", body: { token: "tok" } },
    { pattern: "\\/api\\/links\\?", body: { data: [
      { id: "u-1", name: "Golden", url: "https://a.com", slug: "golden", createdAt: "2026-01-01T00:00:00Z", deletedAt: null, customDomain: { domain: "t.brand.com" } },
      { id: "u-2", name: "Gone", url: "https://a.com/x", slug: "gone", createdAt: "2026-01-01T00:00:00Z", deletedAt: "2026-02-01T00:00:00Z" },
      { id: "u-3", name: "Known", url: "https://a.com/k", slug: "known", createdAt: "2026-01-01T00:00:00Z", deletedAt: null },
    ], count: 3 } },
    { pattern: "\\/websites\\/u-1\\/events.*page=1&", body: { data: [
      { sessionId: "s1", createdAt: "2026-03-01T00:00:00Z", urlPath: "/golden", urlQuery: "utm_source=newsletter", referrerDomain: "", referrerPath: "", country: "GB", city: "London", device: "mobile", os: "iOS", browser: "ios" },
      { sessionId: "s2", createdAt: "2026-03-01T01:00:00Z", urlPath: "/golden", urlQuery: "", referrerDomain: "google.com", referrerPath: null, country: "US", city: null, device: "desktop", os: "Mac OS", browser: "chrome" },
    ], count: 3 } },
    { pattern: "\\/websites\\/u-1\\/events.*page=2&", body: { data: [{ sessionId: "s9", createdAt: "2026-03-02T00:00:00Z", urlPath: "/golden", urlQuery: "", referrerDomain: "t.co", referrerPath: "/x", country: "FR", city: "Paris", device: "mobile", os: "Android", browser: "chrome" }], count: 3 } },
    { pattern: "\\/websites\\/u-1\\/sessions", body: { data: [{ id: "s1", screen: "390x844", language: "en-GB", region: "ENG" }, { id: "s2", screen: "1920x1080", language: "en-US", region: "CA" }], count: 2 } },
  ], known: ["known https://a.com/k"] },
  { name: "umami key paged", source: "umami", credentials: { url: "http://stats.example.com", apiKey: "k" }, routes: [
    { pattern: "\\/api\\/links\\?page=1&", body: { data: Array.from({ length: 5 }, (_, i) => ({ id: `u${i}`, name: `N${i}`, url: `https://a.com/${i}`, slug: `s${i}`, createdAt: "2026-01-01T00:00:00Z", deletedAt: null })), count: 6 } },
    { pattern: "\\/api\\/links\\?page=2&", body: { data: [{ id: "u5", name: "N5", url: "https://a.com/5", slug: "s5", createdAt: "x", deletedAt: null }], count: 6 } },
    { pattern: "\\/websites\\/", body: { data: [], count: 0 } },
  ], known: ["u0", "u1", "u2", "u3", "u4"] },
  { name: "umami login paged", source: "umami", credentials: { url: "https://stats.example.com", username: "jon", password: "pw" }, routes: [
    { pattern: "\\/api\\/auth\\/login", body: { token: "tok" } },
    { pattern: "\\/api\\/links\\?page=1&", body: { data: Array.from({ length: 5 }, (_, i) => ({ id: `u${i}`, name: `N${i}`, url: `https://a.com/${i}`, slug: `s${i}`, createdAt: "2026-01-01T00:00:00Z", deletedAt: null })), count: 6 } },
    { pattern: "\\/api\\/links\\?page=2&", body: { data: [], count: 6 } },
  ], known: ["u0", "u1", "u2", "u3", "u4"] },
  { name: "umami wrong password", source: "umami", credentials: { url: "https://stats.example.com", username: "jon", password: "bad" }, routes: [
    { pattern: "\\/api\\/auth\\/login", body: {} },
    { pattern: "\\/api\\/links\\?", body: { data: [], count: 0 } },
  ] },
  { name: "umami no address", source: "umami", credentials: { url: "nope" }, routes: [] },
  { name: "umami no login", source: "umami", credentials: { url: "https://stats.example.com", username: "jon" }, routes: [] },
];

const importers = [];
for (const s of scenarios) {
  const requests: Recorded[] = [];
  const waits: number[] = [];
  const knownCalls: unknown[] = [];
  const left = s.routes.map((r) => r.times ?? Infinity);
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    requests.push(record(input, init));
    const url = String(input);
    for (const [i, route] of s.routes.entries()) {
      if (left[i]! <= 0 || !new RegExp(route.pattern).test(url)) continue;
      left[i]!--;
      if (route.unreachable) throw new TypeError("fetch failed");
      return new Response(JSON.stringify(route.body), { status: route.status ?? 200, headers: { "content-type": "application/json", ...route.headers } });
    }
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
  const realTimeout = globalThis.setTimeout;
  globalThis.setTimeout = ((fn: () => void, ms: number) => {
    waits.push(ms);
    queueMicrotask(fn);
    return 0;
  }) as never;
  const known = async (sourceId: string, slug?: string, url?: string) => {
    knownCalls.push([sourceId, slug ?? null, url ?? null]);
    return (s.known ?? []).includes(sourceId) || (s.known ?? []).includes(`${slug} ${url}`);
  };
  const steps = [];
  let cursor: string | null = s.cursor ?? null;
  for (let i = 0; i < 10; i++) {
    try {
      const result = await IMPORTERS[s.source]!.step({ credentials: s.credentials, cursor, known });
      steps.push({ cursor, result: JSON.parse(JSON.stringify(result)) });
      cursor = result.cursor;
      if (!cursor) break;
    } catch (e) {
      steps.push({ cursor, error: { ...failure(e), name: (e as Error).constructor.name } });
      break;
    }
  }
  globalThis.setTimeout = realTimeout;
  globalThis.fetch = realFetch;
  importers.push({ name: s.name, source: s.source, credentials: s.credentials, routes: s.routes, known: s.known ?? [], ordered: s.source !== "umami", requests, waits, knownCalls, steps });
}

const out = new URL("../packages/php/tests/fixtures/outbound.json", import.meta.url);
writeFileSync(out, `${JSON.stringify({ note: "Written by scripts/php-fixtures-outbound.mts from the TypeScript SDK. Do not edit.", now: NOW, mail: mailCases, replies: replies.map((reply) => ({ reply, message: serviceMessage(reply) })), signatures, mimes, smtp, sealed, ips, icons, importers }, null, 1)}\n`);
console.log(`Wrote ${out.pathname}`);
