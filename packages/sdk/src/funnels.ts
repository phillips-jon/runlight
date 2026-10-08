import { pagePattern } from "./goals.js";
import { randomId } from "./hash.js";
import type { FunnelRow, FunnelStep } from "./store.js";

/** Why a funnel was refused, as a code the dashboard says in its own words. */
export class FunnelError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly params: Record<string, string> = {},
  ) {
    super(message);
  }
}

/**
 * Checks and tidies a funnel from the dashboard: a name, and two to eight
 * steps, each a page (with * as a wildcard) or an event name.
 */
export function funnelFrom(input: Record<string, unknown>, site: string, existing: FunnelRow[], now: number, id?: string): FunnelRow {
  const name = String(input.name ?? "").trim().slice(0, 80);
  if (!name) throw new FunnelError("Give the funnel a name", "funnel_name");
  if (existing.some((f) => f.id !== id && f.name.toLowerCase() === name.toLowerCase())) throw new FunnelError(`There is already a funnel called "${name}"`, "funnel_exists", { name });
  const raw = Array.isArray(input.steps) ? input.steps : [];
  const steps: FunnelStep[] = [];
  for (const item of raw) {
    const step = (item && typeof item === "object" ? item : {}) as Record<string, unknown>;
    const kind = step.kind === "event" ? "event" : "page";
    let match = String(step.match ?? "").trim().slice(0, 500);
    if (!match) continue;
    if (kind === "page") {
      // A full URL is fine to paste; the path is what counts.
      const path = pagePattern(match);
      if (path === null) throw new FunnelError(`"${match}" is not a path or a URL`, "funnel_page_bad", { match });
      match = path;
    }
    steps.push({ kind, match });
  }
  if (steps.length < 2) throw new FunnelError("A funnel needs at least two steps", "funnel_short");
  if (steps.length > 8) throw new FunnelError("A funnel has at most eight steps", "funnel_long");
  return { id: id ?? randomId(), site, name, steps, createdAt: existing.find((f) => f.id === id)?.createdAt ?? now };
}
