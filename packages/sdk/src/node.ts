/**
 * @runlight/sdk/node: serve Runlight from Node's http module and the
 * frameworks built on it (Express, Connect, and Koa through ctx.req and ctx.res).
 *
 *   import { toNodeHandler, observer } from "@runlight/sdk/node";
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
    if (size > limit) throw new BodyTooLarge(`Request body over ${limit} bytes`);
    chunks.push(buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export async function toRequest(req: NodeRequest): Promise<Request> {
  const method = (req.method ?? "GET").toUpperCase();
  const init: RequestInit = { method, headers: headersOf(req) };
  if (method !== "GET" && method !== "HEAD") {
    const path = (req.originalUrl ?? req.url ?? "").split("?")[0] ?? "";
    init.body = await readBody(req, /\/e$/.test(path) ? MAX_COLLECT_BODY : MAX_BODY);
  }
  return new Request(toUrl(req), init);
}

export async function writeResponse(res: ServerResponse, response: Response): Promise<void> {
  res.statusCode = response.status;
  response.headers.forEach((value, key) => {
    if (key === "set-cookie") return;
    res.setHeader(key, value);
  });
  const cookies = response.headers.getSetCookie();
  if (cookies.length > 0) res.setHeader("set-cookie", cookies);
  res.end(response.body ? Buffer.from(await response.arrayBuffer()) : undefined);
}

/**
 * A handler for http.createServer, Express, or Connect. Requests outside the
 * routes' basePath go to next() when there is one.
 */
export function toNodeHandler(handler: FetchHandler): NodeHandler {
  return async (req, res, next) => {
    try {
      const response = await handler(await toRequest(req), { ip: req.socket?.remoteAddress ?? "" });
      if (response.status === 404 && next && response.headers.get("content-type")?.includes("json")) {
        const body = (await response.clone().json().catch(() => null)) as { error?: string } | null;
        if (body?.error === "Not found") return next();
      }
      await writeResponse(res, response);
    } catch (error) {
      if (error instanceof BodyTooLarge) {
        res.statusCode = 413;
        res.setHeader("content-type", "application/json; charset=utf-8");
        return void res.end(JSON.stringify({ error: "That request is too large" }));
      }
      if (next) return next(error);
      res.statusCode = 500;
      res.end();
    }
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
