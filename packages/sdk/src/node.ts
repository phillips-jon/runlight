/**
 * @runlight/sdk/node: serve Runlight from Node's http module and the
 * frameworks built on it (Express, Connect, and Koa through ctx.req and ctx.res).
 *
 *   import { toNodeHandler, observer, shortLinks } from "@runlight/sdk/node";
 *   app.use(shortLinks(rl));                        // link domains and /go/{slug}
 *   app.use(observer(rl));                          // AI agent fetches
 *   app.use(toNodeHandler(rl.routes().handler));    // the routes, under /runlight
 */
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Runlight } from "./runlight.js";
import type { FetchHandler } from "./routes.js";

export type NodeNext = (error?: unknown) => void;
export type NodeHandler = (req: IncomingMessage, res: ServerResponse, next?: NodeNext) => Promise<void>;

type NodeRequest = IncomingMessage & { originalUrl?: string; body?: unknown };

/** The collect endpoint's limit; its payloads are under 8 KB. */
const MAX_COLLECT_BODY = 16 * 1024;
/** Everything else, such as a link import of 5,000 rows. */
const MAX_BODY = 10 * 1024 * 1024;

/**
 * How much of a body past its limit is read and thrown away, so the client
 * finishes sending and reads the 413 rather than a reset connection. Past
 * this the connection is cut.
 */
const MAX_DRAIN = 64 * 1024 * 1024;

/** A body past the limit, answered with 413 rather than passed on empty. */
export class BodyTooLarge extends Error {}

function toUrl(req: NodeRequest): string {
  const encrypted = (req.socket as { encrypted?: boolean } | undefined)?.encrypted === true;
  const proto = (String(req.headers["x-forwarded-proto"] ?? "").split(",")[0]?.trim() || (encrypted ? "https" : "http")).toLowerCase();
  const host = String(req.headers.host ?? "localhost");
  const target = req.originalUrl ?? req.url ?? "/";
  try {
    return new URL(target.startsWith("/") ? target : `/${target}`, `${proto === "https" ? "https" : "http"}://${host}`).toString();
  } catch {
    return "http://localhost/";
  }
}

function headersOf(req: IncomingMessage): Headers {
  const headers = new Headers();
  for (const [key, value] of Object.entries(req.headers)) {
    if (key.startsWith(":") || value === undefined) continue;
    for (const v of Array.isArray(value) ? value : [value]) headers.append(key, v);
  }
  return headers;
}

async function readBody(req: NodeRequest, limit: number): Promise<string> {
  // A body parser may have read the stream already.
  if (typeof req.body === "string") return req.body;
  if (req.body instanceof Uint8Array) return new TextDecoder().decode(req.body);
  if (req.body && typeof req.body === "object") return JSON.stringify(req.body);
  if (req.readableEnded) return "";
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buffer = typeof chunk === "string" ? Buffer.from(chunk) : (chunk as Buffer);
    size += buffer.length;
    if (size > limit + MAX_DRAIN) break;
    if (size <= limit) chunks.push(buffer);
  }
  if (size > limit) throw new BodyTooLarge(`Request body over ${limit} bytes`);
  return Buffer.concat(chunks).toString("utf8");
}

/**
 * The request as a fetch Request. Given the response too, its signal fires when
 * the client goes away before the response is finished, so a report or a
 * pass-through to a connected install stops once nobody is waiting for it.
 */
export async function toRequest(req: NodeRequest, res?: ServerResponse): Promise<Request> {
  const method = (req.method ?? "GET").toUpperCase();
  const init: RequestInit = { method, headers: headersOf(req) };
  if (res) {
    const controller = new AbortController();
    res.once("close", () => {
      if (!res.writableFinished) controller.abort(new Error("The client went away"));
    });
    init.signal = controller.signal;
  }
  if (method !== "GET" && method !== "HEAD") {
    const path = (req.originalUrl ?? req.url ?? "").split("?")[0] ?? "";
    init.body = await readBody(req, /\/e$/.test(path) ? MAX_COLLECT_BODY : MAX_BODY);
  }
  return new Request(toUrl(req), init);
}

/** Waits until the response takes more, or is closed. */
function drained(res: ServerResponse): Promise<void> {
  return new Promise((resolve) => {
    const done = () => {
      res.off("drain", done);
      res.off("close", done);
      resolve();
    };
    res.on("drain", done);
    res.on("close", done);
  });
}

/**
 * Sends a fetch Response, streaming its body as it comes and only as fast as
 * the client takes it, so an export or a pass-through is never held whole in
 * memory. A client that goes away stops the reading.
 */
export async function writeResponse(res: ServerResponse, response: Response): Promise<void> {
  res.statusCode = response.status;
  response.headers.forEach((value, key) => {
    if (key === "set-cookie") return;
    res.setHeader(key, value);
  });
  const cookies = response.headers.getSetCookie();
  if (cookies.length > 0) res.setHeader("set-cookie", cookies);
  if (!response.body) return void res.end();
  const reader = response.body.getReader();
  const gone = () => void reader.cancel().catch(() => {});
  res.once("close", gone);
  try {
    for (;;) {
      if (res.destroyed) return;
      const { done, value } = await reader.read();
      if (done) break;
      if (!res.write(value)) await drained(res);
    }
    res.end();
  } catch {
    // A body that fails before its first byte is a plain 500; one that fails partway is a cut
    // connection, rather than a short answer that looks whole.
    if (res.headersSent) return void res.destroy();
    for (const name of res.getHeaderNames()) res.removeHeader(name);
    res.statusCode = 500;
    res.end();
  } finally {
    res.off("close", gone);
  }
}

/**
 * A handler for http.createServer, Express, or Connect. Requests outside the
 * routes' basePath go to next() when there is one, and when the handler is
 * routes().handler, the bodies of those requests are left for the app.
 */
export function toNodeHandler(handler: FetchHandler): NodeHandler {
  const base = (handler as { basePath?: unknown }).basePath;
  return async (req, res, next) => {
    // A request for the app, outside the routes, goes on with its body unread, so the app's own parsers still see it.
    const path = ((req as NodeRequest).originalUrl ?? req.url ?? "/").split("?")[0] ?? "/";
    if (next && typeof base === "string" && base !== "" && path !== base && !path.startsWith(`${base}/`) && !["GET", "HEAD", "OPTIONS"].includes(req.method ?? "GET")) {
      return next();
    }
    try {
      const response = await handler(await toRequest(req, res), { ip: req.socket?.remoteAddress ?? "" });
      if (response.status === 404 && next && response.headers.get("content-type")?.includes("json")) {
        const body = (await response.clone().json().catch(() => null)) as { error?: string } | null;
        if (body?.error === "Not found") return next();
      }
      await writeResponse(res, response);
    } catch (error) {
      if (error instanceof BodyTooLarge) {
        // An upload cut off part way leaves the connection unfit for another request.
        res.statusCode = 413;
        res.setHeader("connection", "close");
        res.setHeader("content-type", "application/json; charset=utf-8");
        return void res.end(JSON.stringify({ error: "That request is too large" }));
      }
      if (next) return next(error);
      res.statusCode = 500;
      res.end();
    }
  };
}

/**
 * Express or Connect middleware for short links, to go before the app's own
 * routes. A request on a link domain added in Settings gets the link's
 * redirect, or a 404 for a path with no link, except under the dashboard's
 * paths, which reach the app so its owner can always open it. A GET for
 * `{linkPath}/{slug}` on any other host gets the redirect when the link
 * exists. Everything else, including a slug with no link, goes to next()
 * untouched, its body unread.
 *
 * Without next, as in a plain http server, it resolves to true when it
 * answered and false when the app should.
 */
export function shortLinks(runlight: Runlight): (req: IncomingMessage, res: ServerResponse, next?: NodeNext) => Promise<boolean> {
  const own = new RegExp(`^${runlight.linkPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/[^/]+$`);
  const follow = runlight.linkHandler();
  return async (req, res, next) => {
    try {
      // Only the address and headers are read, so the app still gets the body.
      const request = new Request(toUrl(req as NodeRequest), { method: (req.method ?? "GET").toUpperCase(), headers: headersOf(req) });
      const context = { ip: req.socket?.remoteAddress ?? "" };
      let answer = await runlight.linkDomainResponse(request, context);
      if (!answer && request.method === "GET" && own.test(new URL(request.url).pathname)) {
        // A slug that is not valid percent-encoding is no link, so it is the app's too.
        const followed = await follow(request, context).catch((error: unknown) => {
          if (error instanceof URIError) return null;
          throw error;
        });
        if (followed && followed.status !== 404) answer = followed;
      }
      if (answer) {
        await writeResponse(res, answer);
        return true;
      }
    } catch (error) {
      if (next) {
        next(error);
        return true;
      }
      throw error;
    }
    next?.();
    return false;
  };
}

/** Express or Connect middleware that records AI agent fetches and always calls next(). */
export function observer(runlight: Runlight): (req: IncomingMessage, res: ServerResponse, next: NodeNext) => void {
  return (req, _res, next) => {
    if (req.method === "GET") {
      void runlight.observe(new Request(toUrl(req as NodeRequest), { headers: headersOf(req) }));
    }
    next();
  };
}
