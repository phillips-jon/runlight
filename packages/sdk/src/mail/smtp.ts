import type { MailConfig, Message } from "./transports.js";
import { MailError } from "./transports.js";

/**
 * A small SMTP client: implicit TLS (465), STARTTLS (587), or plain (local
 * relays), with AUTH PLAIN. Node only; imported lazily so edge runtimes that
 * never use SMTP never load node:net.
 */

const b64 = (text: string) => Buffer.from(text, "utf8").toString("base64");
const wrap = (text: string) => text.replace(/.{1,76}/g, "$&\r\n");
const encodeWord = (text: string) => (/^[\x20-\x7e]*$/.test(text) ? text : `=?UTF-8?B?${b64(text)}?=`);

/** The message as MIME: text and HTML alternatives, both base64. Exported for its test. */
export function mime(m: Message, from: string, now = new Date()): string {
  const boundary = `rl-${crypto.randomUUID()}`;
  const domain = m.from.split("@")[1] ?? "runlight.local";
  const named = /^(.*)<(.+)>$/.exec(from);
  const fromHeader = named ? `${encodeWord(named[1]!.trim())} <${named[2]}>` : from;
  const headers = [
    `From: ${fromHeader}`,
    `To: ${m.to}`,
    `Subject: ${encodeWord(m.subject)}`,
    `Date: ${now.toUTCString().replace("GMT", "+0000")}`,
    `Message-ID: <${crypto.randomUUID()}@${domain}>`,
    "MIME-Version: 1.0",
    ...Object.entries(m.headers ?? {}).map(([k, v]) => `${k}: ${v.replace(/[\r\n]/g, "")}`),
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
  ];
  return [
    headers.join("\r\n"),
    "",
    `--${boundary}`,
    "Content-Type: text/plain; charset=utf-8",
    "Content-Transfer-Encoding: base64",
    "",
    wrap(b64(m.text)),
    `--${boundary}`,
    "Content-Type: text/html; charset=utf-8",
    "Content-Transfer-Encoding: base64",
    "",
    wrap(b64(m.html)),
    `--${boundary}--`,
    "",
  ].join("\r\n");
}

type Socket = import("node:net").Socket;

/** Reads SMTP replies, multi-line included, one at a time. */
function replies(socket: Socket) {
  let buffer = "";
  const waiting: Array<(line: { code: number; text: string } | Error) => void> = [];
  const ready: Array<{ code: number; text: string }> = [];
  let failure: Error | null = null;
  const deliver = (reply: { code: number; text: string } | Error) => {
    const next = waiting.shift();
    if (next) next(reply);
    else if (reply instanceof Error) failure = reply;
    else ready.push(reply);
  };
  let lines: string[] = [];
  const onData = (chunk: Buffer) => {
    buffer += chunk.toString("utf8");
    let at: number;
    while ((at = buffer.indexOf("\r\n")) >= 0) {
      const line = buffer.slice(0, at);
      buffer = buffer.slice(at + 2);
      lines.push(line.slice(4));
      if (line[3] !== "-") {
        deliver({ code: Number(line.slice(0, 3)), text: lines.join(" ") });
        lines = [];
      }
    }
  };
  socket.on("data", onData);
  socket.on("error", (e) => deliver(new MailError(`SMTP: ${e.message}`)));
  socket.on("close", () => deliver(new MailError("SMTP: the server closed the connection")));
  return {
    next(): Promise<{ code: number; text: string }> {
      if (failure) return Promise.reject(failure);
      const r = ready.shift();
      if (r) return Promise.resolve(r);
      return new Promise((resolve, reject) => waiting.push((x) => (x instanceof Error ? reject(x) : resolve(x))));
    },
    detach() {
      socket.off("data", onData);
    },
  };
}

export async function smtpSend(config: MailConfig, m: Message, from: string): Promise<void> {
  const net = await import("node:net");
  const tls = await import("node:tls");
  const host = config.host!.trim();
  const security = config.security || "starttls";
  const port = Number(config.port) || (security === "tls" ? 465 : 587);
  const timeout = 20_000;

  let socket: Socket = await new Promise<Socket>((resolve, reject) => {
    const s: Socket = security === "tls" ? tls.connect({ host, port, servername: host }, () => resolve(s)) : net.connect({ host, port }, () => resolve(s));
    s.setTimeout(timeout, () => s.destroy(new Error("timed out")));
    s.once("error", (e) => reject(new MailError(`SMTP: could not connect to ${host}:${port}: ${e.message}`, "mail_unreachable", { host: `${host}:${port}`, detail: e.message })));
  });
  let reader = replies(socket);
  const write = (line: string) => socket.write(`${line}\r\n`);
  const expect = async (codes: number[], what: string) => {
    const reply = await reader.next();
    if (!codes.includes(reply.code)) throw new MailError(`SMTP ${what}: ${reply.code} ${reply.text}`.slice(0, 300));
    return reply;
  };

  try {
    await expect([220], "greeting");
    const name = from.split("@")[1]?.replace(/>$/, "") || "localhost";
    write(`EHLO ${name}`);
    let ehlo = await expect([250], "EHLO");
    if (security === "starttls") {
      if (!/STARTTLS/i.test(ehlo.text)) throw new MailError("SMTP: the server does not offer STARTTLS; pick tls or none", "smtp_starttls", {});
      write("STARTTLS");
      await expect([220], "STARTTLS");
      reader.detach();
      socket = await new Promise<Socket>((resolve, reject) => {
        const secured = tls.connect({ socket, servername: host }, () => resolve(secured));
        secured.once("error", (e) => reject(new MailError(`SMTP: TLS failed: ${e.message}`)));
      });
      reader = replies(socket);
      write(`EHLO ${name}`);
      ehlo = await expect([250], "EHLO");
    }
    if (config.username) {
      write(`AUTH PLAIN ${b64(`\0${config.username}\0${config.password ?? ""}`)}`);
      await expect([235], "sign-in");
    }
    write(`MAIL FROM:<${m.from}>`);
    await expect([250], "MAIL FROM");
    write(`RCPT TO:<${m.to}>`);
    await expect([250, 251], "RCPT TO");
    write("DATA");
    await expect([354], "DATA");
    // A line starting with a dot gets a second one, so it is not read as the end.
    socket.write(`${mime(m, from).replace(/\r\n\./g, "\r\n..")}\r\n.\r\n`);
    await expect([250], "message");
    write("QUIT");
    // Wait for the goodbye, but never fail a sent message over it.
    await Promise.race([reader.next().catch(() => null), new Promise((r) => setTimeout(r, 2000))]);
  } finally {
    socket.end();
  }
}
