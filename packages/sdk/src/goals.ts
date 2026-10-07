import { randomId } from "./hash.js";
import type { GoalRow, SiteRow } from "./store.js";

export class GoalError extends Error {}

const KINDS = ["event", "page", "click"] as const;
const MODES = ["none", "fixed", "prop"] as const;
const PROP = /^[A-Za-z0-9_.-]{1,40}$/;

/**
 * Checks and tidies a goal from the dashboard. `existing` is the site's
 * other goals, so two goals cannot share a name.
 */
export function goalFrom(input: Record<string, unknown>, site: string, existing: GoalRow[], now: number, id?: string): GoalRow {
  const text = (key: string, max: number) => String(input[key] ?? "").trim().slice(0, max);
  const name = text("name", 80);
  if (!name) throw new GoalError("Give the goal a name");
  if (existing.some((g) => g.id !== id && g.name.toLowerCase() === name.toLowerCase())) throw new GoalError(`There is already a goal called "${name}"`);

  const kind = String(input.kind ?? "") as GoalRow["kind"];
  if (!KINDS.includes(kind)) throw new GoalError("Pick what the goal counts: an event, a page visit, or a click");

  let match = text("match", 500);
  let clickBy: GoalRow["clickBy"] = "";
  if (kind === "event" && !match) throw new GoalError("Enter the event's name");
  if (kind === "page") {
    if (!match) throw new GoalError("Enter a page path, like /thanks or /blog/*");
    // A full URL is fine to paste; the path is what counts.
    if (/^https?:\/\//i.test(match)) {
      try {
        const url = new URL(match.replace(/\*/g, "__STAR__"));
        match = url.pathname.replace(/__STAR__/g, "*") || "/";
      } catch {
        throw new GoalError("That page is not a path or a URL");
      }
    }
    if (!match.startsWith("/") && !match.startsWith("*")) match = `/${match}`;
  }
  if (kind === "click") {
    clickBy = input.clickBy === "link" ? "link" : "selector";
    if (!match) throw new GoalError(clickBy === "link" ? "Enter the link's address, like https://buy.stripe.com/*" : "Enter a CSS selector, like #signup or .buy-button");
  }

  const valueMode = (MODES as readonly string[]).includes(String(input.valueMode)) ? (String(input.valueMode) as GoalRow["valueMode"]) : "none";
  const value = valueMode === "fixed" ? Number(input.value) : 0;
  if (valueMode === "fixed" && !(Number.isFinite(value) && value >= 0 && value < 1e9)) throw new GoalError("Enter an amount, like 49 or 9.99");
  const valueProp = valueMode === "prop" ? text("valueProp", 40) || "revenue" : "";
  if (valueMode === "prop" && !PROP.test(valueProp)) throw new GoalError("A property name uses letters, numbers, dots, dashes, and underscores");
  const currency = text("currency", 20).toUpperCase() || "USD";
  if (!/^[A-Z]{3}$/.test(currency)) throw new GoalError("Use a three-letter currency code, like USD or EUR");

  const before = existing.find((g) => g.id === id);
  return {
    id: id ?? randomId(),
    site,
    name,
    kind,
    match,
    clickBy,
    valueMode,
    value: Math.round(value * 100) / 100,
    valueProp,
    currency,
    createdAt: before?.createdAt ?? now,
  };
}

/** One click rule for the tracker: [s for selector or h for a link, what to match, the event to send]. */
export type ClickRule = [string, string, string];

/**
 * Click rules for the tracker, keyed by site id and by each of the site's
 * hostnames (or "*" for a site with none), so the script finds its own.
 */
export function clickRules(sites: SiteRow[], goals: GoalRow[]): Record<string, ClickRule[]> {
  const out: Record<string, ClickRule[]> = {};
  for (const site of sites) {
    const rules: ClickRule[] = goals
      .filter((g) => g.site === site.id && g.kind === "click")
      .map((g) => [g.clickBy === "link" ? "h" : "s", g.match, g.name]);
    if (rules.length === 0) continue;
    out[site.id] = rules;
    for (const host of site.hostnames.length ? site.hostnames : ["*"]) out[host.replace(/^www\./, "")] = rules;
  }
  return out;
}
