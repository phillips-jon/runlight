import { readJsonCapped } from "../body.js";
import { PrivateAddressError, publicFetch } from "../safefetch.js";
import { ImportError } from "./types.js";

/** JSON over HTTPS with a timeout and a few retries on rate limits and server errors. */
export class HttpError extends ImportError {
  constructor(
    message: string,
    readonly status: number,
    code: string,
    params: Record<string, string> = {},
  ) {
    super(message, code, params);
  }
}

export const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The most one answer may weigh; a page of a thousand events is well under a megabyte. */
const MAX_BYTES = 32 * 1024 * 1024;

/**
 * The address can come from whoever runs an import (a self-hosted Umami), so
 * only public https addresses are asked, with no redirect followed, which
 * would carry the key somewhere else.
 */
export async function getJson<T>(url: string, init: { headers?: Record<string, string>; method?: string; body?: string } = {}): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    let response: Response;
    try {
      response = await publicFetch(url, { ...init, headers: { accept: "application/json", ...init.headers }, timeoutMs: 20_000 });
    } catch (error) {
      if (attempt < 3 && !(error instanceof PrivateAddressError)) continue;
      throw new ImportError(`Could not reach ${new URL(url).host}`, "unreachable", { host: new URL(url).host });
    }
    if (response.ok) return await readJsonCapped<T>(response, MAX_BYTES);
    if (response.status === 401) throw new HttpError("The key or sign-in was refused", 401, "import_refused");
    if ((response.status === 429 || response.status >= 500) && attempt < 4) {
      // Retry-After in seconds; none, zero, negative, or not a number waits the default backoff.
      const after = Number(response.headers.get("retry-after")) * 1000;
      const wait = after > 0 ? after : 800 * attempt;
      await new Promise((r) => setTimeout(r, Math.min(wait, 10_000)));
      continue;
    }
    throw new HttpError(`${new URL(url).host} answered ${response.status}`, response.status, "import_status", { host: new URL(url).host, status: String(response.status) });
  }
}
