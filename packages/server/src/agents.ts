/**
 * npx runlight.sh agents: counts AI agents on a site that has only the script
 * tag, by reading its web server's access log. Agents do not run JavaScript, so
 * the tracker never sees them; the server that answered them did.
 *
 * It reads nginx and Apache's combined format and Caddy's JSON lines, keeps
 * successful GETs from known AI agents, and sends them in batches to a
 * Runlight's /api/observe with the site's observe key. Nothing else in the log
 * leaves the machine. With --follow it keeps reading as the log grows and
 * carries on after the log is rotated. Without it, it reads what is new since
 * the last run (remembered in --state) and stops, for cron.
 */
import { closeSync, existsSync, openSync, readFileSync, readSync, statSync, writeFileSync } from "node:fs";
import { aiAgent } from "@runlight/sdk";

export interface Fetch {
  url: string;
  userAgent: string;
  at: number;
}

/**
 * A request target as a page on the site. Absolute targets ("GET http://other/x", a proxy
 * request) name somewhere else and are skipped; "//x" is a path, not a host.
 */
function pageUrl(target: string, base: string): string | null {
  if (!target.startsWith("/")) return null;
  try {
    return new URL(`/${target.replace(/^\/+/, "")}`, base).href;
  } catch {
    return null;
  }
}

const MONTHS: Record<string, number> = { Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5, Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11 };

/** "07/Oct/2026:13:55:36 -0400" as epoch milliseconds. */
function logTime(value: string): number {
  const m = /^(\d{2})\/(\w{3})\/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})$/.exec(value);
  if (!m || MONTHS[m[2]!] === undefined) return Number.NaN;
  const local = Date.UTC(Number(m[3]), MONTHS[m[2]!]!, Number(m[1]), Number(m[4]), Number(m[5]), Number(m[6]));
  const offset = (Number(m[8]) * 60 + Number(m[9])) * 60_000 * (m[7] === "-" ? -1 : 1);
  return local - offset;
}

// host? ip - user [time] "METHOD /path HTTP/x" status bytes "referrer" "user agent"
const COMBINED = /^(?:(\S+) )?\S+ \S+ \S+ \[([^\]]+)\] "(\S+) (\S+)[^"]*" (\d{3}) \S+ "(?:[^"\\]|\\.)*" "((?:[^"\\]|\\.)*)"/;

/**
 * One log line as a page fetch, or null. `site` is the address pages live at
 * (https://example.com), for formats that do not record the host.
 */
export function parseLine(line: string, site?: string): { method: string; url: string; status: number; userAgent: string; at: number } | null {
  const text = line.trim();
  if (!text) return null;
  if (text.startsWith("{")) {
    // Caddy: {"ts": 1696..., "request": {"method", "host", "uri", "headers": {"User-Agent": [...]}}, "status": 200}
    try {
      const entry = JSON.parse(text) as { ts?: number | string; status?: number; request?: { method?: string; host?: string; uri?: string; proto?: string; tls?: unknown; headers?: Record<string, string[]> } };
      const request = entry.request;
      if (!request?.uri || !request.method) return null;
      const host = request.host ? `${request.tls ? "https" : site?.startsWith("http://") ? "http" : "https"}://${request.host}` : site;
      if (!host) return null;
      const ua = request.headers?.["User-Agent"]?.[0] ?? request.headers?.["user-agent"]?.[0] ?? "";
      const at = typeof entry.ts === "number" ? entry.ts * 1000 : Date.parse(String(entry.ts ?? ""));
      const url = pageUrl(request.uri, host);
      if (!url) return null;
      return { method: request.method, url, status: Number(entry.status ?? 0), userAgent: ua, at };
    } catch {
      return null;
    }
  }
  const m = COMBINED.exec(text);
  if (!m) return null;
  // A vhost column first ("example.com:443 1.2.3.4 - - [...]") names the host; otherwise --site does.
  const vhost = m[1] && /[a-z]/i.test(m[1]) && !/^[\d.:]+$/.test(m[1]) ? m[1].replace(/:\d+$/, "") : null;
  const base = vhost ? `https://${vhost}` : site;
  if (!base) return null;
  const url = pageUrl(m[4]!, base);
  return url ? { method: m[3]!, url, status: Number(m[5]), userAgent: m[6]!.replace(/\\"/g, '"'), at: logTime(m[2]!) } : null;
}

/** The lines worth sending: GETs that succeeded, from known AI agents. */
export function agentFetch(line: string, site?: string): Fetch | null {
  const hit = parseLine(line, site);
  if (!hit || hit.method !== "GET" || hit.status < 200 || hit.status >= 400 || !aiAgent(hit.userAgent)) return null;
  return { url: hit.url, userAgent: hit.userAgent, at: Number.isFinite(hit.at) ? hit.at : Date.now() };
}

export interface AgentsOptions {
  log: string;
  /** The Runlight to report to, as its dashboard address. */
  to: string;
  key: string;
  site?: string;
  follow?: boolean;
  /** Where one-shot runs remember how far they read. */
  state?: string;
  out?: (line: string) => void;
}

/** Sends fetches to /api/observe, 500 at a time, and returns how many Runlight kept. */
async function send(options: AgentsOptions, fetches: Fetch[]): Promise<number> {
  let kept = 0;
  for (let i = 0; i < fetches.length; i += 500) {
    const answer = await fetch(`${options.to.replace(/\/+$/, "")}/api/observe`, {
      method: "POST",
      headers: { authorization: `Bearer ${options.key}`, "content-type": "application/json" },
      body: JSON.stringify({ fetches: fetches.slice(i, i + 500) }),
      signal: AbortSignal.timeout(30_000),
    });
    if (answer.status === 401) throw new Error("Runlight refused the key. Use the site's key from Settings, Install, Key for CMS plugins.");
    if (!answer.ok) throw new Error(`Runlight answered ${answer.status}: ${(await answer.text()).slice(0, 200)}`);
    const body = (await answer.json().catch(() => null)) as { recorded?: number } | null;
    kept += body?.recorded ?? 0;
  }
  return kept;
}

/** The most of a log read at once, so a log of any size fits in memory a piece at a time. */
const CHUNK = 32 * 1024 * 1024;

/**
 * Reads whole lines from a byte offset, at most a chunk, and returns where the next read starts.
 * The offset counts bytes up to the last newline byte, so a malformed character cannot shift it.
 */
function readFrom(file: string, offset: number): { lines: string[]; next: number; more: boolean } {
  const size = statSync(file).size;
  if (size <= offset) return { lines: [], next: offset, more: false };
  const fd = openSync(file, "r");
  try {
    const buffer = Buffer.alloc(Math.min(size - offset, CHUNK));
    readSync(fd, buffer, 0, buffer.length, offset);
    const end = buffer.lastIndexOf(0x0a);
    // A half-written last line waits for the next read (or, in a chunk with no newline at all, is skipped).
    if (end < 0) return buffer.length === CHUNK ? { lines: [], next: offset + buffer.length, more: true } : { lines: [], next: offset, more: false };
    return { lines: buffer.subarray(0, end).toString("utf8").split("\n"), next: offset + end + 1, more: offset + buffer.length < size };
  } finally {
    closeSync(fd);
  }
}

export async function runAgents(options: AgentsOptions): Promise<number> {
  const out = options.out ?? ((line: string) => console.log(line));
  if (!existsSync(options.log)) throw new Error(`No log at ${options.log}`);
  let total = 0;
  let warned = false;
  const handle = async (lines: string[]) => {
    const fetches = lines.map((line) => agentFetch(line, options.site)).filter((f): f is Fetch => f !== null);
    // Lines with no host and no --site cannot be placed on a site; say so once rather than skip them silently.
    if (!options.site && !warned && lines.some((line) => !line.trim().startsWith("{") && /"\S+ \/\S* [^"]*" \d{3}/.test(line) && !parseLine(line))) {
      warned = true;
      out("Some lines have no host in them. Add --site https://your-site.example so they can be counted.");
    }
    const kept = fetches.length ? await send(options, fetches) : 0;
    total += kept;
    return kept;
  };
  const save = (ino: number, offset: number) => {
    if (options.state) writeFileSync(options.state, JSON.stringify({ ino, offset }));
  };

  if (!options.follow) {
    // Where the last run stopped, unless the log was rotated since (a new file, or a shorter one).
    type Saved = { ino: number; offset: number };
    const saved: Saved | null = options.state && existsSync(options.state) ? (JSON.parse(readFileSync(options.state, "utf8")) as Saved) : null;
    const stat = statSync(options.log);
    let offset = saved && saved.ino === stat.ino && saved.offset <= stat.size ? saved.offset : 0;
    let count = 0;
    // A chunk at a time, saving the place after each, so a failure part way resends nothing already sent.
    for (;;) {
      const { lines, next, more } = readFrom(options.log, offset);
      await handle(lines);
      count += lines.length;
      offset = next;
      save(stat.ino, offset);
      if (!more) break;
    }
    out(`Sent ${total} AI agent fetches from ${count} new lines.`);
    return total;
  }

  // Follow: start where --state says, else at the end like tail -F, and start over when the log is replaced.
  type Saved = { ino: number; offset: number };
  const resumed: Saved | null = options.state && existsSync(options.state) ? (JSON.parse(readFileSync(options.state, "utf8")) as Saved) : null;
  let ino = statSync(options.log).ino;
  let offset = resumed && resumed.ino === ino && resumed.offset <= statSync(options.log).size ? resumed.offset : statSync(options.log).size;
  out(`Following ${options.log}. AI agent fetches go to ${options.to} as they happen.`);
  for (;;) {
    await new Promise((resolve) => setTimeout(resolve, 2000));
    if (!existsSync(options.log)) continue;
    const stat = statSync(options.log);
    if (stat.ino !== ino || stat.size < offset) {
      ino = stat.ino;
      offset = 0;
    }
    const { lines, next } = readFrom(options.log, offset);
    try {
      const sent = await handle(lines);
      // Only past lines that were sent, so a failed send is tried again next time.
      offset = next;
      save(ino, offset);
      if (sent) out(`Sent ${sent} AI agent fetches.`);
    } catch (error) {
      out(`Could not send, trying again shortly: ${(error as Error).message}`);
    }
  }
}
