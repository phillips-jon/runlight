import type { MailConfig, Message } from "./transports.js";
import { MailError, serviceMessage } from "./transports.js";

/**
 * Amazon SES (API v2) with a hand-rolled Signature Version 4, so there is no
 * AWS SDK to install. https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
 */
const encoder = new TextEncoder();
const hex = (bytes: ArrayBuffer) => Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
const sha256 = async (text: string) => hex(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
async function hmac(key: ArrayBuffer | Uint8Array<ArrayBuffer>, text: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, encoder.encode(text));
}

/** Signs a request; exported for its test against AWS's published example. */
export async function signV4(input: {
  method: string;
  url: URL;
  body: string;
  region: string;
  service: string;
  accessKeyId: string;
  secretAccessKey: string;
  now: Date;
  headers: Record<string, string>;
}): Promise<Record<string, string>> {
  const amzDate = input.now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const day = amzDate.slice(0, 8);
  const payloadHash = await sha256(input.body);
  const headers: Record<string, string> = { ...input.headers, host: input.url.host, "x-amz-date": amzDate };
  const names = Object.keys(headers).map((h) => h.toLowerCase()).sort();
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v.trim().replace(/\s+/g, " ")]));
  const canonical = [
    input.method,
    input.url.pathname.split("/").map((p) => encodeURIComponent(decodeURIComponent(p))).join("/") || "/",
    [...input.url.searchParams].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&"),
    names.map((n) => `${n}:${lower[n]}\n`).join(""),
    names.join(";"),
    payloadHash,
  ].join("\n");
  const scope = `${day}/${input.region}/${input.service}/aws4_request`;
  const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, await sha256(canonical)].join("\n");
  let key = await hmac(encoder.encode(`AWS4${input.secretAccessKey}`), day);
  key = await hmac(key, input.region);
  key = await hmac(key, input.service);
  key = await hmac(key, "aws4_request");
  const signature = hex(await hmac(key, toSign));
  return {
    ...headers,
    authorization: `AWS4-HMAC-SHA256 Credential=${input.accessKeyId}/${scope}, SignedHeaders=${names.join(";")}, Signature=${signature}`,
  };
}

export async function sesSend(config: MailConfig, m: Message, from: string): Promise<void> {
  const region = config.region!.trim();
  if (!/^[a-z]{2}(-[a-z]+)+-\d$/.test(region)) throw new MailError("That is not an AWS region, like us-east-1");
  const url = new URL(`https://email.${region}.amazonaws.com/v2/email/outbound-emails`);
  const body = JSON.stringify({
    FromEmailAddress: from,
    Destination: { ToAddresses: [m.to] },
    Content: {
      Simple: {
        Subject: { Data: m.subject, Charset: "UTF-8" },
        Body: { Html: { Data: m.html, Charset: "UTF-8" }, Text: { Data: m.text, Charset: "UTF-8" } },
        Headers: Object.entries(m.headers ?? {}).map(([Name, Value]) => ({ Name, Value })),
      },
    },
  });
  const headers = await signV4({
    method: "POST",
    url,
    body,
    region,
    service: "ses",
    accessKeyId: config.accessKeyId!.trim(),
    secretAccessKey: config.secretAccessKey!.trim(),
    now: new Date(),
    headers: { "content-type": "application/json" },
  });
  delete headers.host;
  let response: Response;
  try {
    response = await fetch(url, { method: "POST", headers, body, signal: AbortSignal.timeout(20_000) });
  } catch (error) {
    throw new MailError(`Could not reach Amazon SES: ${(error as Error).message}`);
  }
  if (!response.ok) {
    const message = serviceMessage(await response.text().catch(() => ""));
    throw new MailError(`Amazon SES answered ${response.status}${message ? `: ${message}` : ""}`);
  }
}
