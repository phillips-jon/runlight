import { randomId } from "./hash.js";
import { recordedPath } from "./sources.js";
import type { GoalRow, SiteRow } from "./store.js";

/** Why a goal was refused, as a code the dashboard says in its own words. */
export class GoalError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly params: Record<string, string> = {},
  ) {
    super(message);
  }
}

/**
 * A page to match, written the way paths are recorded: the path of a pasted URL, with a leading slash,
 * percent-encoded as browsers send it, so /café matches the recorded /caf%C3%A9, and with a hash
 * route kept, so /#/thanks counts only that route. `*` stays a wildcard. Null when it is not a path or a URL.
 */
export function pagePattern(input: string): string | null {
  const starred = input.replace(/\*/g, "__STAR__");
  // A pattern written to start with * keeps that start, rather than gaining a slash.
  const path = recordedPath(starred.startsWith("__STAR__") ? `/${starred}` : starred);
  if (path === null) return null;
  const pattern = path.replace(/__STAR__/g, "*");
  return input.startsWith("*") ? pattern.replace(/^\//, "") : pattern;
}

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
  if (!name) throw new GoalError("Give the goal a name", "goal_name");
  if (existing.some((g) => g.id !== id && g.name.toLowerCase() === name.toLowerCase())) throw new GoalError(`There is already a goal called "${name}"`, "goal_exists", { name });

  const kind = String(input.kind ?? "") as GoalRow["kind"];
  if (!KINDS.includes(kind)) throw new GoalError("Pick what the goal counts: an event, a page visit, or a click", "goal_kind");

  let match = text("match", 500);
  let clickBy: GoalRow["clickBy"] = "";
  if (kind === "event" && !match) throw new GoalError("Enter the event's name", "goal_event");
  if (kind === "page") {
    if (!match) throw new GoalError("Enter a page path, like /thanks or /blog/*", "goal_page");
    // A full URL is fine to paste; the path is what counts.
    const path = pagePattern(match);
    if (path === null) throw new GoalError("That page is not a path or a URL", "goal_page_bad");
    match = path;
  }
  if (kind === "click") {
    clickBy = input.clickBy === "link" ? "link" : "selector";
    if (!match) throw clickBy === "link" ? new GoalError("Enter the link's address, like https://buy.stripe.com/*", "goal_link") : new GoalError("Enter a CSS selector, like #signup or .buy-button", "goal_selector");
  }

  // A click goal sends an event named after itself, so its name and an event goal's match must not meet.
  const others = existing.filter((g) => g.id !== id);
  if (kind === "click" && others.some((g) => g.kind === "event" && g.match.toLowerCase() === name.toLowerCase())) {
    throw new GoalError(`An event goal already counts events called "${name}", so give this click goal another name`, "goal_event_taken", { name });
  }
  if (kind === "event" && others.some((g) => g.kind === "click" && g.name.toLowerCase() === match.toLowerCase())) {
    throw new GoalError(`The click goal "${match}" already sends events with that name`, "goal_click_taken", { match });
  }

  const valueMode = (MODES as readonly string[]).includes(String(input.valueMode)) ? (String(input.valueMode) as GoalRow["valueMode"]) : "none";
  // Page visits and click rules carry no properties, so only an event can send its own amount.
  if (valueMode === "prop" && kind !== "event") throw new GoalError("Only an event goal can take its amount from the event; use a fixed amount instead", "goal_prop_kind");
  const value = valueMode === "fixed" ? Number(input.value) : 0;
  if (valueMode === "fixed" && !(Number.isFinite(value) && value >= 0 && value < 1e9)) throw new GoalError("Enter an amount, like 49 or 9.99", "goal_amount");
  const valueProp = valueMode === "prop" ? text("valueProp", 40) || "revenue" : "";
  if (valueMode === "prop" && !PROP.test(valueProp)) throw new GoalError("A property name uses letters, numbers, dots, dashes, and underscores", "goal_prop_name");
  const currency = text("currency", 20).toUpperCase() || "USD";
  if (!/^[A-Z]{3}$/.test(currency)) throw new GoalError("Use a three-letter currency code, like USD or EUR", "goal_currency");

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
