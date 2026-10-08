import { randomId } from "./hash.js";
import type { Runlight } from "./runlight.js";
import { stripWww } from "./sources.js";
import type { LinkRow } from "./store.js";

/** What a person or an import may set on a link. */
export interface LinkInput {
  url: string;
  name?: string;
  slug?: string;
  /** A link domain added in Settings, or "" (the default) for the app's own. */
  domain?: string;
}

export const SLUG_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/;
const ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789";

/** Six characters from an alphabet without look-alikes (no 0/o, 1/l). */
export function randomSlug(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  return Array.from(bytes, (b) => ALPHABET[b % ALPHABET.length]).join("");
}

/** A link that cannot be made. `code` and `params` let the dashboard say it in its own language. */
export class LinkError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly params: Record<string, string> = {},
  ) {
    super(message);
  }
}

function cleanUrl(value: unknown): string {
  const text = String(value ?? "").trim();
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    throw new LinkError("The destination must be a full URL, starting with https://", "link_url");
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new LinkError("The destination must start with http:// or https://", "link_protocol");
  if (text.length > 2000) throw new LinkError("The destination is longer than 2,000 characters", "link_long");
  return url.toString();
}

function defaultName(url: string): string {
  const u = new URL(url);
  return `${stripWww(u.hostname)}${u.pathname === "/" ? "" : u.pathname}`.slice(0, 100);
}

/** Short links: create, change, delete, and import, with the rules every route shares. */
export class Links {
  constructor(private readonly runlight: Runlight) {}

  private async domainFor(site: string, value: unknown): Promise<string> {
    const domain = stripWww(String(value ?? "").trim());
    if (!domain) return "";
    const known = await this.runlight.store.linkDomains();
    if (!known.some((d) => d.domain === domain && d.site === site)) throw new LinkError(`Add ${domain} as a link domain in Settings first`, "link_domain", { domain });
    return domain;
  }

  /** Slugs are unique across every domain, so a link can always fall back to the app's own path. */
  private async freeSlug(wanted: string | undefined, except?: string): Promise<string> {
    if (wanted !== undefined && wanted !== "") {
      if (!SLUG_PATTERN.test(wanted)) throw new LinkError("A slug is letters, digits, dashes, and underscores, up to 100", "link_slug");
      const taken = await this.runlight.store.linkBySlug(wanted);
      if (taken && taken.id !== except) throw new LinkError(`/${wanted} is already taken`, "link_taken", { slug: wanted });
      return wanted;
    }
    for (let i = 0; i < 8; i++) {
      const slug = randomSlug();
      if (!(await this.runlight.store.linkBySlug(slug))) return slug;
    }
    throw new LinkError("Could not find a free slug; try again", "link_no_slug");
  }

  async create(site: string, input: LinkInput): Promise<LinkRow> {
    await this.runlight.init();
    const url = cleanUrl(input.url);
    const domain = await this.domainFor(site, input.domain);
    const slug = await this.freeSlug(input.slug?.trim());
    const now = this.runlight.now();
    const link: LinkRow = {
      id: randomId(),
      site,
      domain,
      slug,
      name: (input.name?.trim() || defaultName(url)).slice(0, 100),
      url,
      createdAt: now,
      updatedAt: now,
    };
    await this.runlight.store.insertLink(link);
    return link;
  }

  async update(id: string, input: Partial<LinkInput>): Promise<LinkRow> {
    await this.runlight.init();
    const link = await this.runlight.store.linkById(id);
    if (!link) throw new RangeError("Unknown link");
    const next = { ...link };
    if (input.url !== undefined) next.url = cleanUrl(input.url);
    if (input.name !== undefined) next.name = String(input.name).trim().slice(0, 100) || defaultName(next.url);
    // Keeping a link's domain needs no check, even while that domain is removed.
    if (input.domain !== undefined && stripWww(input.domain.trim()) !== link.domain) next.domain = await this.domainFor(link.site, input.domain);
    if (input.slug !== undefined) next.slug = await this.freeSlug(input.slug.trim(), link.id);
    next.updatedAt = this.runlight.now();
    await this.runlight.store.updateLink(next);
    return next;
  }

  async remove(id: string): Promise<void> {
    await this.runlight.init();
    if (!(await this.runlight.store.linkById(id))) throw new RangeError("Unknown link");
    await this.runlight.store.deleteLink(id, this.runlight.now());
  }

  /**
   * Creates many links at once, as from a CSV. Rows that fail are reported
   * with their reason and the rest go in. Headers match the Umami fork's
   * export: name or link_name, url or destination_url, slug or link_slug,
   * domain or tracking_domain.
   */
  async import(
    site: string,
    rows: Array<Record<string, unknown>>,
  ): Promise<{ created: number; failed: Array<{ row: number; reason: string; code: string; params: Record<string, string> }> }> {
    const failed: Array<{ row: number; reason: string; code: string; params: Record<string, string> }> = [];
    let created = 0;
    for (const [i, raw] of rows.entries()) {
      const pick = (...keys: string[]) => {
        for (const key of keys) {
          const value = raw[key];
          if (typeof value === "string" && value.trim()) return value.trim();
        }
        return undefined;
      };
      try {
        await this.create(site, {
          url: pick("url", "destination_url") ?? "",
          name: pick("name", "link_name"),
          slug: pick("slug", "link_slug"),
          domain: pick("domain", "tracking_domain"),
        });
        created++;
      } catch (error) {
        // A bad row is reported and skipped; a failing database stops the whole import.
        if (!(error instanceof LinkError)) throw error;
        failed.push({ row: i + 1, reason: error.message, code: error.code, params: error.params });
      }
    }
    return { created, failed };
  }
}
