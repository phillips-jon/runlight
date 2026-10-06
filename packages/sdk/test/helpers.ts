import { runlight, type RunlightOptions } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

export const CHROME_MAC =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
export const SAFARI_IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

/** A Runlight on an in-memory database with a clock the test moves. */
export function setup(options: Partial<RunlightOptions> = {}) {
  let now = Date.UTC(2026, 9, 6, 12, 0);
  const rl = runlight({ store: sqlite({ path: ":memory:" }), now: () => now, ...options });
  const routes = rl.routes({ token: "secret" });

  const send = async (body: Record<string, unknown>, init: { ua?: string; ip?: string; headers?: Record<string, string> } = {}) => {
    const response = await routes.POST(
      new Request("https://example.com/runlight/e", {
        method: "POST",
        body: JSON.stringify(body),
        headers: { "user-agent": init.ua ?? CHROME_MAC, "x-forwarded-for": init.ip ?? "203.0.113.1", ...init.headers },
      }),
    );
    if (response.status !== 202) throw new Error(`collect answered ${response.status}`);
  };

  const get = async (path: string): Promise<any> => {
    const response = await routes.GET(new Request(`https://example.com/runlight${path}`, { headers: { authorization: "Bearer secret" } }));
    if (response.status !== 200) throw new Error(`${path} answered ${response.status}: ${await response.text()}`);
    return response.json();
  };

  return {
    rl,
    routes,
    send,
    get,
    advance(ms: number) {
      now += ms;
    },
    get now() {
      return now;
    },
  };
}
