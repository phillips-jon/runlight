/**
 * npx runlight.sh agents: counts AI agents on a site that has only the script
 * tag, by reading its web server's access log. Agents do not run JavaScript, so
 * the tracker never sees them; the server that answered them did.
 *
 * It reads nginx and Apache's combined format and Caddy's JSON lines, keeps
 * successful GETs from known AI agents, and sends them in batches to a
 * Runlight's /api/observe with the site's observe key. Nothing else in the log
 * leaves the machine. With --follow it keeps reading as the log grows and
 * carries on after the log is rotated. Without it, it reads what is new and
 * stops, for cron. In both modes --state remembers how far it read, so the
 * next run, or a restarted --follow, carries on from there.
 */
import { createHash } from "node:crypto";
import { closeSync, existsSync, fstatSync, linkSync, openSync, readFileSync, readSync, renameSync, statSync, unlinkSync, writeFileSync, writeSync } from "node:fs";
import { aiAgent } from "@runlight/sdk";

export interface Fetch {
  url: string;
  userAgent: string;
  at: number;
}

/**
 * A request target as a page on the site. Absolute targets ("GET http://other/x", a proxy
 * request) name somewhere else and are skipped. The target is set as the path and query of the
 * site's own address, never parsed as a URL, so "//x" and "/\x" stay paths on the site.
 */
function pageUrl(target: string, base: string): string | null {
  if (!target.startsWith("/")) return null;
  try {
    const url = new URL(base);
    const query = target.indexOf("?");
    url.pathname = `/${(query < 0 ? target : target.slice(0, query)).replace(/^\/+/, "")}`;
    url.search = query < 0 ? "" : target.slice(query);
    url.hash = "";
    return url.href;
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
  /** Where runs remember how far they read, so the next one (or a restarted --follow) carries on. */
  state?: string;
  out?: (line: string) => void;
  /** Ends --follow, which otherwise runs until the process stops. */
  stop?: AbortSignal;
  /** How often --follow looks at the log, 2 seconds by default. */
  pollMs?: number;
}

/** The most fetches /api/observe takes at once. */
const BATCH = 500;

/** A failure to reach Runlight or have it take a batch, told apart from a failure to read the log. */
class SendError extends Error {}

/** Sends one batch of fetches to /api/observe and returns how many Runlight kept. */
async function send(options: AgentsOptions, fetches: Fetch[]): Promise<number> {
  const answer = await fetch(`${options.to.replace(/\/+$/, "")}/api/observe`, {
    method: "POST",
    headers: { authorization: `Bearer ${options.key}`, "content-type": "application/json" },
    body: JSON.stringify({ fetches }),
    signal: AbortSignal.timeout(30_000),
  }).catch((error: Error) => {
    throw new SendError(error.message);
  });
  if (answer.status === 401) throw new SendError("Runlight refused the key. Use the site's key from Settings, Install, Key for CMS plugins.");
  if (!answer.ok) throw new SendError(`Runlight answered ${answer.status}: ${(await answer.text()).slice(0, 200)}`);
  const body = (await answer.json().catch(() => null)) as { recorded?: number } | null;
  return body?.recorded ?? 0;
}

/** Where a run stopped: the log's inode, the byte offset, and a fingerprint of the log's start. */
type Saved = { ino: number; offset: number; head?: string; length?: number };

/** The most of a log read at once, so a log of any size fits in memory a piece at a time. */
const CHUNK = 32 * 1024 * 1024;

/** How many bytes at the start of a log identify it. */
const HEAD = 256;

/**
 * A fingerprint of the log's first bytes. A log rotated by copying and truncating keeps its inode,
 * so a different start is how a new log shows itself. An open file (in follow mode) is read as it is,
 * even once it is renamed.
 */
function headOf(file: string | number, length = HEAD): { head: string; length: number } {
  const fd = typeof file === "number" ? file : openSync(file, "r");
  try {
    const buffer = Buffer.alloc(Math.min(length, fstatSync(fd).size));
    readSync(fd, buffer, 0, buffer.length, 0);
    return { head: createHash("sha256").update(buffer).digest("hex"), length: buffer.length };
  } finally {
    if (typeof file !== "number") closeSync(fd);
  }
}

/** Whether the log at this inode still starts the way it did, so a saved place in it still holds. */
function sameLog(file: string, saved: { ino: number; head?: string; length?: number }, stat: { ino: number; size: number }): boolean {
  if (saved.ino !== stat.ino) return false;
  if (!saved.head || saved.length === undefined) return true;
  return stat.size >= saved.length && headOf(file, saved.length).head === saved.head;
}

/**
 * Reads whole lines from a byte offset, at most a chunk, and returns where the next read starts.
 * Offsets count bytes up to each newline byte, so a malformed character cannot shift them. `ends`
 * holds where the line after each one starts, so a place can be saved part way through a chunk.
 */
function readFrom(file: string | number, offset: number): { lines: string[]; ends: number[]; next: number; more: boolean } {
  // A path is opened for this read; an open file (in follow mode) stays open, even once it is renamed.
  const size = typeof file === "number" ? fstatSync(file).size : statSync(file).size;
  if (size <= offset) return { lines: [], ends: [], next: offset, more: false };
  const fd = typeof file === "number" ? file : openSync(file, "r");
  try {
    const buffer = Buffer.alloc(Math.min(size - offset, CHUNK));
    readSync(fd, buffer, 0, buffer.length, offset);
    const end = buffer.lastIndexOf(0x0a);
    // A half-written last line waits for the next read (or, in a chunk with no newline at all, is skipped).
    if (end < 0) return buffer.length === CHUNK ? { lines: [], ends: [], next: offset + buffer.length, more: true } : { lines: [], ends: [], next: offset, more: false };
    const lines: string[] = [];
    const ends: number[] = [];
    for (let start = 0; start <= end; ) {
      const newline = buffer.indexOf(0x0a, start);
      lines.push(buffer.subarray(start, newline).toString("utf8"));
      ends.push(offset + newline + 1);
      start = newline + 1;
    }
    return { lines, ends, next: offset + end + 1, more: offset + buffer.length < size };
  } finally {
    if (typeof file !== "number") closeSync(fd);
  }
}

/** Whether a process with this id is running on this machine. */
function running(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM: it runs, as someone else.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

/**
 * Takes the lock beside a state file, so two runs never read from the same place and send the
 * same lines twice. The lock holds the run's process id; a lock left by a process that is no longer
 * running is taken over. Returns the release.
 */
function lock(state: string): () => void {
  const path = `${state}.lock`;
  const mine = String(process.pid);
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const fd = openSync(path, "wx");
      writeSync(fd, mine);
      closeSync(fd);
      const release = () => {
        try {
          if (readFileSync(path, "utf8") === mine) unlinkSync(path);
        } catch {}
      };
      process.once("exit", release);
      return () => {
        process.off("exit", release);
        release();
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    }
    let held = "";
    try {
      held = readFileSync(path, "utf8").trim();
    } catch {
      continue;
    }
    const pid = Number(held);
    // A lock being written has no id in it yet, so it counts as held.
    if (!held || (Number.isInteger(pid) && pid > 0 && running(pid))) break;
    // Stale. Moving it aside is atomic, so of two runs taking it over only one moves this lock; one
    // that finds a newer lock moved aside puts it back.
    const aside = `${path}.${mine}`;
    try {
      renameSync(path, aside);
    } catch {
      continue;
    }
    if (readFileSync(aside, "utf8").trim() !== held) {
      try {
        linkSync(aside, path);
      } catch {}
      unlinkSync(aside);
      break;
    }
    unlinkSync(aside);
  }
  let holder = "";
  try {
    holder = readFileSync(path, "utf8").trim();
  } catch {}
  throw new Error(`Another run is using ${state}${holder ? ` (process ${holder})` : ""}. Wait for it to finish, or delete ${path} if none is running.`);
}

/** Writes the state whole or not at all, so a crash part way never leaves it empty. */
function writeState(state: string, saved: Saved): void {
  const temp = `${state}.${process.pid}.tmp`;
  writeFileSync(temp, JSON.stringify(saved));
  renameSync(temp, state);
}

export async function runAgents(options: AgentsOptions): Promise<number> {
  const release = options.state ? lock(options.state) : () => {};
  try {
    return await readLog(options);
  } finally {
    release();
  }
}

async function readLog(options: AgentsOptions): Promise<number> {
  const out = options.out ?? ((line: string) => console.log(line));
  if (!existsSync(options.log)) throw new Error(`No log at ${options.log}`);
  let total = 0;
  let warned = false;
  /**
   * Sends the agent fetches among lines read, a batch at a time, calling `done` with where the next
   * unsent line starts after each batch, so a failure part way sends none of the earlier batches again.
   */
  const handle = async (read: { lines: string[]; ends: number[] }, done: (offset: number) => void) => {
    const { lines, ends } = read;
    // Lines with no host and no --site cannot be placed on a site; say so once rather than skip them silently.
    if (!options.site && !warned && lines.some((line) => !line.trim().startsWith("{") && /"\S+ \/\S* [^"]*" \d{3}/.test(line) && !parseLine(line))) {
      warned = true;
      out("Some lines have no host in them. Add --site https://your-site.example so they can be counted.");
    }
    let kept = 0;
    let batch: Fetch[] = [];
    for (let i = 0; i < lines.length; i++) {
      const found = agentFetch(lines[i]!, options.site);
      if (found) batch.push(found);
      if (batch.length === BATCH || (i === lines.length - 1 && batch.length)) {
        const recorded = await send(options, batch);
        kept += recorded;
        total += recorded;
        batch = [];
        done(ends[i]!);
      }
    }
    return kept;
  };
  /** The place to save: the file being read, by its inode and its own start, and how far into it. */
  const save = (ino: number, offset: number, head: { head: string; length: number }) => {
    if (options.state) writeState(options.state, { ino, offset, ...head });
  };
  /** Where the last run stopped, or null with a word about it when the state file cannot be read. */
  const readState = (): Saved | null => {
    if (!options.state || !existsSync(options.state)) return null;
    try {
      const saved = JSON.parse(readFileSync(options.state, "utf8")) as Saved;
      if (typeof saved?.ino === "number" && typeof saved.offset === "number") return saved;
    } catch {}
    out(`Could not read ${options.state}, so this run starts as if it were the first.`);
    return null;
  };

  if (!options.follow) {
    // Where the last run stopped, unless the log was rotated since (a new file, a shorter one, or a new start).
    const saved = readState();
    const stat = statSync(options.log);
    let offset = saved && saved.offset <= stat.size && sameLog(options.log, saved, stat) ? saved.offset : 0;
    let count = 0;
    // A batch at a time, saving the place after each, so a failure part way resends nothing already sent.
    for (;;) {
      const read = readFrom(options.log, offset);
      await handle(read, (at) => save(stat.ino, at, headOf(options.log)));
      count += read.lines.length;
      offset = read.next;
      save(stat.ino, offset, headOf(options.log));
      if (!read.more) break;
    }
    out(`Sent ${total} AI agent fetches from ${count} new lines.`);
    return total;
  }

  // Follow: start where --state says, else at the end like tail -F. A log that was rotated since the
  // state was saved is all new, so it is read from its start.
  const resumed = readState();
  const first = statSync(options.log);
  let ino = first.ino;
  let offset = resumed ? (resumed.offset <= first.size && sameLog(options.log, resumed, first) ? resumed.offset : 0) : first.size;
  out(`Following ${options.log}. AI agent fetches go to ${options.to} as they happen.`);
  // The log stays open, so when it is renamed in a rotation, what was written to it before the
  // switch is still read to the end before the new log starts. Its fingerprint is taken from the
  // open file too, so a place saved while finishing an old log names that log, never the new one.
  let fd = openSync(options.log, "r");
  let known = headOf(fd);
  // The same trouble every two seconds is said once, until something changes.
  let trouble = "";
  while (!options.stop?.aborted) {
    await new Promise((resolve) => setTimeout(resolve, options.pollMs ?? 2000));
    try {
      const stat = existsSync(options.log) ? statSync(options.log) : null;
      const renamed = !stat || stat.ino !== ino;
      // Copied and truncated in place: the same file, shorter or with a new start.
      if (!renamed && (stat!.size < offset || !sameLog(options.log, { ino, ...known }, stat!))) offset = 0;
      const read = readFrom(fd, offset);
      const sent = await handle(read, (at) => {
        offset = at;
        save(ino, offset, known);
      });
      // Only past lines that were sent, so a failed send is tried again next time.
      offset = read.next;
      save(ino, offset, known);
      if (sent) out(`Sent ${sent} AI agent fetches.`);
      if (renamed && stat && !read.more) {
        // The old log is finished; the new one is read from its start.
        const next = openSync(options.log, "r");
        closeSync(fd);
        fd = next;
        ino = stat.ino;
        offset = 0;
      }
      // The start grows until it is HEAD bytes long, so the fingerprint is taken again each time.
      known = headOf(fd);
      trouble = "";
    } catch (error) {
      const said = error instanceof SendError ? `Could not send, trying again shortly: ${error.message}` : `Could not read ${options.log}, trying again shortly: ${(error as Error).message}`;
      if (said !== trouble) out(said);
      trouble = said;
    }
  }
  closeSync(fd);
  return total;
}
