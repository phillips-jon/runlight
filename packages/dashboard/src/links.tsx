import type { ComponentChildren } from "preact";
import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import { api, type Link, type LinkStats, type Row, type View } from "./api.js";
import { Chart } from "./chart.js";
import { count, countryName, day, flag } from "./format.js";
import { errorText, t, tn, type Key } from "./i18n.js";
import { label } from "./panel.js";
import { Icon } from "./icons.js";
import { useDialogFocus } from "./focus.js";

/**
 * The address people click: at the root of the link's domain while that
 * domain is added, otherwise under the app's own link path, which answers
 * for every link.
 */
export function shortUrl(link: Link, prefix: string, domains: string[]): string {
  return link.domain && domains.includes(link.domain) ? `https://${link.domain}/${link.slug}` : `${prefix}/${link.slug}`;
}

const display = (url: string) => url.replace(/^https?:\/\//, "");
const created = (link: Link) => day(new Date(link.createdAt).toISOString().slice(0, 10));

function Copy({ text, small }: { text: string; small?: boolean }) {
  const [done, setDone] = useState(false);
  return (
    <button
      type="button"
      class={small ? "copy inline" : "copy"}
      onClick={(e) => {
        e.stopPropagation();
        navigator.clipboard
          ?.writeText(text)
          .then(() => {
            setDone(true);
            setTimeout(() => setDone(false), 1500);
          })
          .catch(() => {});
      }}
    >
      <Icon name={done ? "check" : "copy"} />
      {t(done ? "links.copied" : "links.copy")}
    </button>
  );
}

/** Modal frame shared by the link dialogs: Escape and the backdrop close it. */
export function Sheet({ title, sub, wide, onClose, children }: { title: string; sub?: string; wide?: boolean; onClose: () => void; children: ComponentChildren }) {
  const dialog = useRef<HTMLDivElement>(null);
  useDialogFocus(dialog);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    document.addEventListener("keydown", onKey);
    document.body.classList.add("locked");
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.classList.remove("locked");
    };
  }, []);
  return (
    <div class="scrim center" onPointerDown={(e) => e.target === e.currentTarget && onClose()}>
      <div class={wide ? "list-sheet wide link-sheet" : "list-sheet link-sheet small"} role="dialog" aria-modal="true" aria-label={title} ref={dialog}>
        <header class="drawer-head">
          <h2>
            {title} {sub ? <span class="sheet-sub">{sub}</span> : null}
          </h2>
          <button type="button" class="remove" aria-label={t("common.close")} onClick={onClose}>
            <svg viewBox="0 0 16 16" aria-hidden="true">
              <path d="M4 4l8 8M12 4l-8 8" />
            </svg>
          </button>
        </header>
        {children}
      </div>
    </div>
  );
}

/** Create or edit one link. */
export function LinkForm({ site, prefix, domains, link, onClose, onSaved }: {
  site: string;
  prefix: string;
  domains: string[];
  link?: Link;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [url, setUrl] = useState(link?.url ?? "");
  const [name, setName] = useState(link?.name ?? "");
  const [slug, setSlug] = useState(link?.slug ?? "");
  const [domain, setDomain] = useState(link?.domain ?? (domains.length ? domains[0]! : ""));
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [made, setMade] = useState<Link | null>(null);
  const first = useRef<HTMLInputElement>(null);
  useEffect(() => first.current?.focus(), [made]);

  const submit = (e: Event) => {
    e.preventDefault();
    setBusy(true);
    setError("");
    const input = { url: url.trim(), name: name.trim(), slug: slug.trim(), domain };
    (link ? api.updateLink(site, link.id, input) : api.createLink(site, input))
      .then((r) => {
        onSaved();
        if (link) onClose();
        else setMade(r.link);
      })
      .catch((err: Error) => setError(err.message))
      .finally(() => setBusy(false));
  };

  if (made) {
    const address = shortUrl(made, prefix, domains);
    return (
      <Sheet title={t("links.new")} onClose={onClose}>
        <div class="sheet-body link-form">
          <p class="settings-text">{t("links.created")}</p>
          <div class="made">
            <a href={address} target="_blank" rel="noopener">
              {display(address)}
            </a>
            <Copy text={address} />
          </div>
          <p class="field-hint">
            {t("links.destination")} {display(made.url)}
          </p>
          <div class="settings-actions">
            <button
              type="button"
              class="ghost"
              onClick={() => {
                setMade(null);
                setUrl("");
                setName("");
                setSlug("");
              }}
            >
              <Icon name="plus" />
              {t("links.another")}
            </button>
            <button type="button" class="solid" onClick={onClose}>
              {t("common.close")}
            </button>
          </div>
        </div>
      </Sheet>
    );
  }

  return (
    <Sheet title={t(link ? "links.edit" : "links.new")} onClose={onClose}>
      <form class="sheet-body link-form" onSubmit={submit}>
        <label class="field-row">
          <span class="field-label">{t("links.url")}</span>
          <input ref={first} class="value" type="url" required placeholder={t("links.urlPlaceholder")} value={url} onInput={(e) => setUrl((e.target as HTMLInputElement).value)} />
        </label>
        <label class="field-row">
          <span class="field-label">{t("links.name")}</span>
          <input class="value" type="text" maxLength={100} placeholder={t("links.namePlaceholder")} value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
        </label>
        <div class="field-row">
          <span class="field-label">{t("links.slug")}</span>
          <div class="slug-row">
            {domains.length ? (
              <select class="value" aria-label={t("links.domain")} value={domain} onChange={(e) => setDomain((e.target as HTMLSelectElement).value)}>
                {domains.map((d) => (
                  <option value={d}>{d}/</option>
                ))}
                {link?.domain && !domains.includes(link.domain) ? <option value={link.domain}>{t("links.removedDomain", { domain: link.domain })}</option> : null}
                <option value="">{display(prefix)}/</option>
              </select>
            ) : link?.domain ? (
              <select class="value" aria-label={t("links.domain")} value={domain} onChange={(e) => setDomain((e.target as HTMLSelectElement).value)}>
                <option value={link.domain}>{t("links.removedDomain", { domain: link.domain })}</option>
                <option value="">{display(prefix)}/</option>
              </select>
            ) : (
              <span class="slug-prefix">{display(prefix)}/</span>
            )}
            <input class="value" type="text" maxLength={100} pattern="[A-Za-z0-9][A-Za-z0-9_\-]*" placeholder={t("links.slugPlaceholder")} value={slug} onInput={(e) => setSlug((e.target as HTMLInputElement).value)} />
          </div>
        </div>
        <div class="settings-actions">
          {error ? <span class="settings-error">{error}</span> : null}
          <button type="button" class="ghost" onClick={onClose}>
            {t("common.cancel")}
          </button>
          <button type="submit" class="solid" disabled={busy || !url.trim()}>
            <Icon name={link ? "save" : "plus"} />
            {t(link ? "links.save" : "links.create")}
          </button>
        </div>
      </form>
    </Sheet>
  );
}

function MiniList({ title, rows, dimension }: { title: Key; rows: Row[]; dimension: string }) {
  const top = Math.max(1, ...rows.map((r) => Number(r.events ?? 0)));
  return (
    <section class="mini">
      <h3>{t(title)}</h3>
      {rows.length === 0 ? <p class="empty">{t("panel.empty")}</p> : null}
      <ol class="rows">
        {rows.map((r) => (
          <li>
            <span class="bar" style={{ width: `${(Number(r.events ?? 0) / top) * 100}%` }} />
            <span class="name">
              <span class="name-text">{dimension === "country" ? `${flag(r.value)} ${countryName(r.value)}` : label(dimension, r.value)}</span>
            </span>
            <span class="num">{count(Number(r.events ?? 0))}</span>
          </li>
        ))}
      </ol>
    </section>
  );
}

/** One link's clicks over the dashboard's range, and where they came from. */
export function LinkDetail({ view, id, prefix, domains, onClose }: { view: View; id: string; prefix: string; domains: string[]; onClose: () => void }) {
  const [stats, setStats] = useState<LinkStats | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    api.link(view, id).then(setStats).catch((e: Error) => setError(e.message));
  }, [view, id]);
  const address = stats ? shortUrl(stats.link, prefix, domains) : "";
  const series = [
    { key: "clicks", slot: 1, label: t("links.clicksLabel"), format: count },
    { key: "visitors", slot: 2, label: t("metric.visitors"), format: count },
  ];
  return (
    <Sheet title={stats?.link.name ?? t("common.loading")} sub={stats ? tn("links.total", stats.clicks, { n: count(stats.clicks) }) : undefined} wide onClose={onClose}>
      <div class="sheet-body">
        {error ? <p class="failure">{error}</p> : null}
        {stats ? (
          <>
            <div class="link-head">
              <div class="made">
                <a href={address} target="_blank" rel="noopener">
                  {display(address)}
                </a>
                <Copy text={address} />
              </div>
              <p class="field-hint">
                {t("links.destination")}{" "}
                <a href={stats.link.url} target="_blank" rel="noopener">
                  {display(stats.link.url)}
                </a>
                <span class="link-date-inline">{t("links.createdOn", { date: created(stats.link) })}</span>
              </p>
            </div>
            <h3 class="mini-title">{t("links.clicksOverTime")}</h3>
            <div class="link-chart">
              <Chart points={stats.series} metrics={series} interval={stats.range.interval} timezone={stats.range.timezone} shared height={240} />
            </div>
            <div class="mini-grid">
              <MiniList title="links.sources" rows={stats.sources} dimension="source" />
              <MiniList title="links.countries" rows={stats.countries} dimension="country" />
              <MiniList title="links.devices" rows={stats.devices} dimension="device" />
              <MiniList title="links.browsers" rows={stats.browsers} dimension="browser" />
            </div>
          </>
        ) : null}
      </div>
    </Sheet>
  );
}

/** A small CSV reader: quoted fields, doubled quotes, commas and newlines inside quotes. */
export function parseCsv(text: string): Array<Record<string, string>> {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') {
        field += '"';
        i++;
      } else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ",") {
      row.push(field);
      field = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field);
      field = "";
      if (row.some((x) => x.trim())) rows.push(row);
      row = [];
    } else field += c;
  }
  row.push(field);
  if (row.some((x) => x.trim())) rows.push(row);
  const [header, ...body] = rows;
  if (!header) return [];
  const keys = header.map((k) => k.trim().toLowerCase().replace(/^﻿/, ""));
  return body.map((cells) => Object.fromEntries(keys.map((k, i) => [k, (cells[i] ?? "").trim()])));
}

type Sort = "clicks" | "newest" | "name";
const PAGE = 100;

/** Two steps, so a stray click never deletes: the first arms it for a few seconds. */
export function DeleteButton({ name, onDelete }: { name: string; onDelete: () => void }) {
  const [armed, setArmed] = useState(false);
  useEffect(() => {
    if (!armed) return;
    const timer = setTimeout(() => setArmed(false), 4000);
    return () => clearTimeout(timer);
  }, [armed]);
  return (
    <button
      type="button"
      class={armed ? "copy inline danger armed" : "copy inline danger"}
      title={armed ? t("links.confirmDelete", { name }) : undefined}
      onClick={() => (armed ? onDelete() : setArmed(true))}
    >
      <Icon name="trash" />
      {armed ? t("links.confirm") : t("links.delete")}
    </button>
  );
}

/** Every link: search, sort, copy, edit, delete, import, and open each one's stats. A viewer only searches, copies, and opens them. */
export function LinkManager({ view, site, readOnly, onClose, onChanged }: { view: View; site: string; readOnly?: boolean; onClose: () => void; onChanged: () => void }) {
  const [links, setLinks] = useState<Link[] | null>(null);
  const [prefix, setPrefix] = useState("");
  const [domains, setDomains] = useState<string[]>([]);
  const [query, setQuery] = useState("");
  const [typed, setTyped] = useState("");
  const [sort, setSort] = useState<Sort>("newest");
  // Draw a page of rows at a time; thousands of rows with buttons make typing sluggish.
  const [limit, setLimit] = useState(PAGE);
  useEffect(() => {
    const timer = setTimeout(() => setQuery(typed), 120);
    return () => clearTimeout(timer);
  }, [typed]);
  useEffect(() => setLimit(PAGE), [query, sort]);
  const [editing, setEditing] = useState<Link | "new" | null>(null);
  const [detail, setDetail] = useState<string | null>(null);
  const [message, setMessage] = useState<{ text: string; failures: Array<{ row: number; reason: string }> } | null>(null);
  const file = useRef<HTMLInputElement>(null);

  const load = () => {
    api
      .links(view)
      .then((r) => {
        setLinks(r.links);
        setPrefix(r.prefix);
        setDomains(r.domains);
      })
      .catch((e: Error) => {
        setLinks((current) => current ?? []);
        setMessage({ text: e.message, failures: [] });
      });
  };
  useEffect(load, [view]);

  const shown = useMemo(() => {
    const needle = query.trim().toLowerCase();
    const list = (links ?? []).filter((l) => !needle || `${l.name} ${l.slug} ${l.url} ${l.domain}`.toLowerCase().includes(needle));
    return list.sort((a, b) =>
      sort === "clicks" ? (b.clicks ?? 0) - (a.clicks ?? 0) || b.createdAt - a.createdAt : sort === "newest" ? b.createdAt - a.createdAt : a.name.localeCompare(b.name),
    );
  }, [links, query, sort]);

  const changed = () => {
    load();
    onChanged();
  };

  const importFile = async (f: File) => {
    try {
      const rows = parseCsv(await f.text());
      // Without a destination column every row would fail, so say why before sending anything.
      if (!rows.some((row) => row.url || row.destination_url)) {
        setMessage({ text: t("links.importNoUrl"), failures: [] });
        return;
      }
      const result = await api.importLinks(site, rows);
      const failures = result.failed.map((f) => ({ row: f.row, reason: (f.code && errorText(f.code, f.params)) || f.reason }));
      setMessage({ text: tn("links.importDone", result.created, { n: count(result.created) }), failures });
      changed();
    } catch (e) {
      setMessage({ text: (e as Error).message, failures: [] });
    }
  };

  if (detail) return <LinkDetail view={view} id={detail} prefix={prefix} domains={domains} onClose={() => setDetail(null)} />;
  if (editing) {
    return (
      <LinkForm
        site={site}
        prefix={prefix}
        domains={domains}
        link={editing === "new" ? undefined : editing}
        onClose={() => setEditing(null)}
        onSaved={changed}
      />
    );
  }

  return (
    <Sheet title={t("panel.links")} sub={links ? (query ? `${count(shown.length)} / ${count(links.length)}` : count(links.length)) : undefined} wide onClose={onClose}>
      <div class="sheet-search link-tools">
        <input class="value" type="search" placeholder={t("links.search")} aria-label={t("links.search")} value={typed} onInput={(e) => setTyped((e.target as HTMLInputElement).value)} />
        <select class="field" aria-label={t("links.sortBy")} value={sort} onChange={(e) => setSort((e.target as HTMLSelectElement).value as Sort)}>
          <option value="newest">{t("links.sortNewest")}</option>
          <option value="clicks">{t("links.sortClicks")}</option>
          <option value="name">{t("links.sortName")}</option>
        </select>
        {readOnly ? null : (
          <>
            <button type="button" class="ghost" title={t("links.importHelp")} onClick={() => file.current?.click()}>
              <Icon name="upload" />
              {t("links.import")}
            </button>
            <input
              ref={file}
              type="file"
              accept=".csv,text/csv"
              hidden
              onChange={(e) => {
                const f = (e.target as HTMLInputElement).files?.[0];
                if (f) void importFile(f);
                (e.target as HTMLInputElement).value = "";
              }}
            />
            <button type="button" class="solid" onClick={() => setEditing("new")}>
              <Icon name="plus" />
              {t("links.new")}
            </button>
          </>
        )}
      </div>
      {message ? (
        <div class="import-result">
          <strong>{message.text}</strong>
          {message.failures.slice(0, 8).map((f) => (
            <span>{t("links.importFailed", { row: f.row, reason: f.reason })}</span>
          ))}
        </div>
      ) : null}
      <div class="sheet-body">
        {links && links.length === 0 ? <p class="empty">{t(readOnly ? "links.noneYet" : "links.empty")}</p> : null}
        <table class="sheet-table links-table">
          <tbody>
            {shown.slice(0, limit).map((l) => {
              const address = shortUrl(l, prefix, domains);
              return (
                <tr>
                  <td class="sheet-name">
                    <button type="button" class="link-cell" onClick={() => setDetail(l.id)}>
                      <span class="link-name">{l.name}</span>
                      <span class="link-short">{display(address)}</span>
                      <span class="link-dest">{display(l.url)}</span>
                      <span class="link-date">{t("links.createdOn", { date: created(l) })}</span>
                    </button>
                  </td>
                  <td class="numeric lead">
                    {count(l.clicks ?? 0)}
                    <span class="link-unit">{t("links.clicks")}</span>
                  </td>
                  <td class="numeric link-actions">
                    <Copy text={address} small />
                    {readOnly ? null : (
                      <>
                        <button type="button" class="copy inline" onClick={() => setEditing(l)}>
                          <Icon name="edit" />
                          {t("links.editButton")}
                        </button>
                        <DeleteButton name={l.name} onDelete={() => api.deleteLink(site, l.id).then(changed, (e: Error) => setMessage({ text: e.message, failures: [] }))} />
                      </>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
        {shown.length > limit ? (
          <div class="more-row">
            <span class="field-hint">{t("links.showing", { shown: count(limit), total: count(shown.length) })}</span>
            <button type="button" class="more" onClick={() => setLimit(limit + PAGE)}>
              <Icon name="plus" />
              {t("links.showMore", { n: PAGE })}
            </button>
          </div>
        ) : null}
      </div>
    </Sheet>
  );
}

/** The board's Links box: the most clicked links in the range, with quick add and the manager a click away. A viewer reads it without changing anything. */
export function LinksPanel({ view, site, readOnly }: { view: View; site: string; readOnly?: boolean }) {
  const [links, setLinks] = useState<Link[] | null>(null);
  const [prefix, setPrefix] = useState("");
  const [domains, setDomains] = useState<string[]>([]);
  const [open, setOpen] = useState<"new" | "manage" | { id: string } | null>(null);
  const [version, setVersion] = useState(0);
  const [order, setOrder] = useState<"newest" | "clicks">("newest");

  useEffect(() => {
    let live = true;
    api
      .links(view)
      .then((r) => {
        if (!live) return;
        setLinks(r.links);
        setPrefix(r.prefix);
        setDomains(r.domains);
      })
      .catch(() => live && setLinks([]));
    return () => {
      live = false;
    };
  }, [view, version]);

  const top = [...(links ?? [])]
    .sort((a, b) => (order === "newest" ? b.createdAt - a.createdAt : (b.clicks ?? 0) - (a.clicks ?? 0) || b.createdAt - a.createdAt))
    .slice(0, 10);
  const max = Math.max(1, ...top.map((l) => l.clicks ?? 0));
  const total = (links ?? []).reduce((sum, l) => sum + (l.clicks ?? 0), 0);

  return (
    <section class="panel wide">
      <header class="panel-head">
        <h2>
          {t("panel.links")} {links ? <span class="aside">{tn("links.total", total, { n: count(total) })}</span> : null}
        </h2>
        <div class="head-tools">
          <nav class="tabs" aria-label={t("links.sortBy")}>
            <button type="button" class={order === "newest" ? "tab on" : "tab"} aria-pressed={order === "newest"} onClick={() => setOrder("newest")}>
              {t("links.sortNewest")}
            </button>
            <button type="button" class={order === "clicks" ? "tab on" : "tab"} aria-pressed={order === "clicks"} onClick={() => setOrder("clicks")}>
              {t("links.sortClicks")}
            </button>
          </nav>
          {readOnly ? null : (
            <>
              <button type="button" class="box-button" onClick={() => setOpen("manage")}>
                <Icon name="list" />
                {t("links.manage")}
              </button>
              <button type="button" class="box-button solid" onClick={() => setOpen("new")}>
                <Icon name="plus" />
                {t("links.new")}
              </button>
            </>
          )}
        </div>
      </header>
      <div class="table">
      <div class="cols">
        <span>{t("panel.links")}</span>
        <span class="num-head">{t("links.clicks")}</span>
      </div>
      {links && top.length === 0 ? <p class="empty">{t(readOnly ? "links.noneYet" : "links.empty")}</p> : null}
      {!links ? <p class="empty">{t("common.loading")}</p> : null}
      <ol class="rows">
        {top.map((l) => (
          <li>
            <span class="bar" style={{ width: `${((l.clicks ?? 0) / max) * 100}%` }} />
            <button type="button" class="name" title={display(shortUrl(l, prefix, domains))} onClick={() => setOpen({ id: l.id })}>
              <span class="name-text">{l.name}</span>
              <span class="link-slug">/{l.slug}</span>
            </button>
            <span class="num">{count(l.clicks ?? 0)}</span>
          </li>
        ))}
      </ol>
      </div>
      {links && links.length > top.length ? (
        <button type="button" class="more" onClick={() => setOpen("manage")}>
          <Icon name="expand" />
          {t("panel.more")}
        </button>
      ) : null}
      {open === "new" ? (
        <LinkForm site={site} prefix={prefix} domains={domains} onClose={() => setOpen(null)} onSaved={() => setVersion((v) => v + 1)} />
      ) : open === "manage" ? (
        <LinkManager view={view} site={site} readOnly={readOnly} onClose={() => setOpen(null)} onChanged={() => setVersion((v) => v + 1)} />
      ) : open ? (
        <LinkDetail view={view} id={open.id} prefix={prefix} domains={domains} onClose={() => setOpen(null)} />
      ) : null}
    </section>
  );
}
