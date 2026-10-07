import { sesSend } from "./ses.js";
import { smtpSend } from "./smtp.js";

export interface Message {
  to: string;
  from: string;
  fromName?: string;
  subject: string;
  html: string;
  text: string;
  /** Extra headers, such as List-Unsubscribe. */
  headers?: Record<string, string>;
}

export class MailError extends Error {}

/** A service's settings: `service` plus its fields. Every value is a string, as typed in the dashboard. */
export type MailConfig = { service: string } & Record<string, string>;

export interface ServiceField {
  name: string;
  label: string;
  /** Never sent back to the browser once saved. */
  secret?: boolean;
  options?: string[];
  optional?: boolean;
  placeholder?: string;
}

/** Every service Runlight can send through, and what each needs. */
export const SERVICES: Array<{ id: string; name: string; fields: ServiceField[] }> = [
  { id: "ses", name: "Amazon SES", fields: [
    { name: "region", label: "Region", placeholder: "us-east-1" },
    { name: "accessKeyId", label: "Access key ID" },
    { name: "secretAccessKey", label: "Secret access key", secret: true },
  ] },
  { id: "resend", name: "Resend", fields: [{ name: "apiKey", label: "API key", secret: true, placeholder: "re_..." }] },
  { id: "postmark", name: "Postmark", fields: [
    { name: "serverToken", label: "Server API token", secret: true },
    { name: "stream", label: "Message stream", optional: true, placeholder: "outbound" },
  ] },
  { id: "sendgrid", name: "SendGrid", fields: [{ name: "apiKey", label: "API key", secret: true, placeholder: "SG...." }] },
  { id: "mailgun", name: "Mailgun", fields: [
    { name: "domain", label: "Sending domain", placeholder: "mg.example.com" },
    { name: "apiKey", label: "API key", secret: true },
    { name: "region", label: "Region", options: ["us", "eu"] },
  ] },
  { id: "brevo", name: "Brevo", fields: [{ name: "apiKey", label: "API key", secret: true, placeholder: "xkeysib-..." }] },
  { id: "mailjet", name: "Mailjet", fields: [
    { name: "apiKey", label: "API key" },
    { name: "secretKey", label: "Secret key", secret: true },
  ] },
  { id: "mailersend", name: "MailerSend", fields: [{ name: "apiKey", label: "API token", secret: true, placeholder: "mlsn...." }] },
  { id: "sparkpost", name: "SparkPost", fields: [
    { name: "apiKey", label: "API key", secret: true },
    { name: "region", label: "Region", options: ["us", "eu"] },
  ] },
  { id: "smtp", name: "SMTP", fields: [
    { name: "host", label: "Host", placeholder: "smtp.example.com" },
    { name: "port", label: "Port", placeholder: "587" },
    { name: "security", label: "Security", options: ["starttls", "tls", "none"] },
    { name: "username", label: "Username", optional: true },
    { name: "password", label: "Password", secret: true, optional: true },
  ] },
  { id: "webhook", name: "Webhook", fields: [
    { name: "url", label: "URL", placeholder: "https://example.com/hooks/mail" },
    { name: "secret", label: "Signing secret", secret: true, optional: true },
  ] },
];

const address = (m: Message) => (m.fromName ? `${m.fromName.replace(/["\\\r\n]/g, "")} <${m.from}>` : m.from);

/**
 * The error a mail service explains itself with, from its JSON or XML reply,
 * and never the raw body: a reply is shown to the dashboard, so an address
 * that is not a mail service must not be able to put its page there.
 */
export function serviceMessage(reply: string): string {
  try {
    const parsed = JSON.parse(reply) as Record<string, unknown>;
    const first = (v: unknown): string => (typeof v === "string" ? v : Array.isArray(v) ? first(v[0]) : v && typeof v === "object" ? first((v as Record<string, unknown>).message) : "");
    return (first(parsed.message) || first(parsed.Message) || first(parsed.error) || first(parsed.errors) || first(parsed.ErrorMessage)).slice(0, 200);
  } catch {
    return (/<Message>([^<]{1,200})<\/Message>/.exec(reply)?.[1] ?? "").trim();
  }
}

async function post(url: string, init: { headers: Record<string, string>; body: string }, explains = true): Promise<void> {
  let response: Response;
  try {
    response = await fetch(url, { method: "POST", headers: init.headers, body: init.body, signal: AbortSignal.timeout(20_000) });
  } catch (error) {
    throw new MailError(`Could not reach ${new URL(url).host}: ${(error as Error).message}`);
  }
  if (response.ok) return;
  const message = explains ? serviceMessage(await response.text().catch(() => "")) : "";
  throw new MailError(`${new URL(url).host} answered ${response.status}${message ? `: ${message}` : ""}`);
}

const json = (headers: Record<string, string> = {}) => ({ "content-type": "application/json", ...headers });
const basic = (user: string, pass: string) => `Basic ${btoa(`${user}:${pass}`)}`;

async function hmacHex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Checks a config has what its service needs, before anything is saved or sent. */
export function checkConfig(config: MailConfig): void {
  const service = SERVICES.find((s) => s.id === config.service);
  if (!service) throw new MailError("Pick a mail service");
  for (const f of service.fields) {
    if (!f.optional && !config[f.name]?.trim()) throw new MailError(`Enter the ${f.label.toLowerCase()}`);
    if (f.options && config[f.name] && !f.options.includes(config[f.name]!)) throw new MailError(`${f.label} must be one of ${f.options.join(", ")}`);
  }
  if (config.service === "webhook" && !/^https:\/\//.test(config.url ?? "") && !/^http:\/\/(localhost|127\.0\.0\.1)/.test(config.url ?? "")) {
    throw new MailError("The webhook URL must use https");
  }
}

/** Sends one message through the configured service. */
export async function send(config: MailConfig, m: Message): Promise<void> {
  checkConfig(config);
  const headers = m.headers ?? {};
  switch (config.service) {
    case "resend":
      return post("https://api.resend.com/emails", {
        headers: json({ authorization: `Bearer ${config.apiKey}` }),
        body: JSON.stringify({ from: address(m), to: [m.to], subject: m.subject, html: m.html, text: m.text, headers }),
      });
    case "postmark":
      return post("https://api.postmarkapp.com/email", {
        headers: json({ accept: "application/json", "x-postmark-server-token": config.serverToken! }),
        body: JSON.stringify({
          From: address(m), To: m.to, Subject: m.subject, HtmlBody: m.html, TextBody: m.text,
          MessageStream: config.stream || "outbound",
          Headers: Object.entries(headers).map(([Name, Value]) => ({ Name, Value })),
        }),
      });
    case "sendgrid":
      return post("https://api.sendgrid.com/v3/mail/send", {
        headers: json({ authorization: `Bearer ${config.apiKey}` }),
        body: JSON.stringify({
          personalizations: [{ to: [{ email: m.to }] }],
          from: { email: m.from, ...(m.fromName ? { name: m.fromName } : {}) },
          subject: m.subject,
          content: [{ type: "text/plain", value: m.text }, { type: "text/html", value: m.html }],
          headers,
        }),
      });
    case "mailgun": {
      const form = new URLSearchParams({ from: address(m), to: m.to, subject: m.subject, html: m.html, text: m.text });
      for (const [k, v] of Object.entries(headers)) form.set(`h:${k}`, v);
      const host = config.region === "eu" ? "api.eu.mailgun.net" : "api.mailgun.net";
      return post(`https://${host}/v3/${encodeURIComponent(config.domain!)}/messages`, {
        headers: { authorization: basic("api", config.apiKey!), "content-type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      });
    }
    case "brevo":
      return post("https://api.brevo.com/v3/smtp/email", {
        headers: json({ "api-key": config.apiKey!, accept: "application/json" }),
        body: JSON.stringify({ sender: { email: m.from, ...(m.fromName ? { name: m.fromName } : {}) }, to: [{ email: m.to }], subject: m.subject, htmlContent: m.html, textContent: m.text, headers }),
      });
    case "mailjet":
      return post("https://api.mailjet.com/v3.1/send", {
        headers: json({ authorization: basic(config.apiKey!, config.secretKey!) }),
        body: JSON.stringify({
          Messages: [{ From: { Email: m.from, ...(m.fromName ? { Name: m.fromName } : {}) }, To: [{ Email: m.to }], Subject: m.subject, TextPart: m.text, HTMLPart: m.html, Headers: headers }],
        }),
      });
    case "mailersend":
      return post("https://api.mailersend.com/v1/email", {
        headers: json({ authorization: `Bearer ${config.apiKey}` }),
        body: JSON.stringify({
          from: { email: m.from, ...(m.fromName ? { name: m.fromName } : {}) }, to: [{ email: m.to }], subject: m.subject, html: m.html, text: m.text,
          ...(Object.keys(headers).length ? { headers: Object.entries(headers).map(([name, value]) => ({ name, value })) } : {}),
        }),
      });
    case "sparkpost":
      return post(`https://${config.region === "eu" ? "api.eu.sparkpost.com" : "api.sparkpost.com"}/api/v1/transmissions`, {
        headers: json({ authorization: config.apiKey! }),
        body: JSON.stringify({
          recipients: [{ address: { email: m.to } }],
          content: { from: m.fromName ? { email: m.from, name: m.fromName } : m.from, subject: m.subject, html: m.html, text: m.text, headers },
        }),
      });
    case "ses":
      return sesSend(config, m, address(m));
    case "smtp":
      return smtpSend(config, m, address(m));
    case "webhook": {
      const body = JSON.stringify({ to: m.to, from: m.from, fromName: m.fromName ?? "", subject: m.subject, html: m.html, text: m.text, headers });
      const signature: Record<string, string> = config.secret ? { "x-runlight-signature": `sha256=${await hmacHex(config.secret, body)}` } : {};
      // A webhook can be any address, so only its status comes back.
      return post(config.url!, { headers: json(signature), body }, false);
    }
  }
  throw new MailError(`Unknown mail service "${config.service}"`);
}
