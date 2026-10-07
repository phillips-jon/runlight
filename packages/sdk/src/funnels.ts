import { randomId } from "./hash.js";
import type { FunnelRow, FunnelStep } from "./store.js";

export class FunnelError extends Error {}

/**
 * Checks and tidies a funnel from the dashboard: a name, and two to eight
 * steps, each a page (with * as a wildcard) or an event name.
 */
export function funnelFrom(input: Record<string, unknown>, site: string, existing: FunnelRow[], now: number, id?: string): FunnelRow {
  const name = String(input.name ?? "").trim().slice(0, 80);
  if (!name) throw new FunnelError("Give the funnel a name");
  if (existing.some((f) => f.id !== id && f.name.toLowerCase() === name.toLowerCase())) throw new FunnelError(`There is already a funnel called "${name}"`);
  const raw = Array.isArray(input.steps) ? input.steps : [];
  const steps: FunnelStep[] = [];
  for (const item of raw) {
    const step = (item && typeof item === "object" ? item : {}) as Record<string, unknown>;
    const kind = step.kind === "event" ? "event" : "page";
    let match = String(step.match ?? "").trim().slice(0, 500);
    if (!match) continue;
    if (kind === "page") {
      // A full URL is fine to paste; the path is what counts.
      if (/^https?:\/\//i.test(match)) {
        try {
          match = new URL(match.replace(/\*/g, "__STAR__")).pathname.replace(/__STAR__/g, "*") || "/";
        } catch {
          throw new FunnelError(`"${match}" is not a path or a URL`);
        }
      }
      if (!match.startsWith("/") && !match.startsWith("*")) match = `/${match}`;
    }
    steps.push({ kind, match });
  }
  if (steps.length < 2) throw new FunnelError("A funnel needs at least two steps");
  if (steps.length > 8) throw new FunnelError("A funnel has at most eight steps");
  return { id: id ?? randomId(), site, name, steps, createdAt: existing.find((f) => f.id === id)?.createdAt ?? now };
}
