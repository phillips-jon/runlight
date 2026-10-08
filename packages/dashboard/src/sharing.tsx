import { useEffect, useState } from "preact/hooks";
import { api, type Share, type Site } from "./api.js";
import { day } from "./format.js";
import { t } from "./i18n.js";
import { Icon } from "./icons.js";
import { DeleteButton } from "./links.js";

// A connected site's shares are served by its own install, so their links start there.
const address = (share: Share, home: string) => `${home}${share.path}`;

function ShareRow({ site, share, home, onChanged }: { site: string; share: Share; home: string; onChanged: () => void }) {
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(share.name);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState("");
  const save = (e: Event) => {
    e.preventDefault();
    setError("");
    void api
      .renameShare(site, share.id, name)
      .then(() => {
        setEditing(false);
        onChanged();
      })
      .catch((err: Error) => setError(err.message));
  };
  return (
    <li>
      <div class="domain-main">
        {editing ? (
          <form class="share-rename" onSubmit={save}>
            <input class="value" type="text" value={name} maxLength={100} autoFocus onInput={(e) => setName((e.target as HTMLInputElement).value)} />
            <button type="submit" class="solid">
              <Icon name="check" />
              {t("share.save")}
            </button>
          </form>
        ) : (
          <span class="share-name">{share.name || t("share.unnamed")}</span>
        )}
        <span class="share-meta">
          {t("links.createdOn", { date: day(new Date(share.createdAt).toISOString().slice(0, 10)) })}
        </span>
      </div>
      <div class="domain-actions">
        <button
          type="button"
          class="copy inline"
          onClick={() =>
            navigator.clipboard
              ?.writeText(address(share, home))
              .then(() => {
                setCopied(true);
                setTimeout(() => setCopied(false), 1600);
              })
              .catch(() => {})
          }
        >
          <Icon name={copied ? "check" : "copy"} />
          {copied ? t("install.copied") : t("install.copy")}
        </button>
        <a class="copy inline" href={address(share, home)} target="_blank" rel="noopener noreferrer">
          <Icon name="external" />
          {t("share.open")}
        </a>
        {editing ? null : (
          <button type="button" class="copy inline" onClick={() => setEditing(true)}>
            <Icon name="edit" />
            {t("share.rename")}
          </button>
        )}
        <DeleteButton name={share.name || t("share.unnamed")} onDelete={() => void api.deleteShare(site, share.id).then(onChanged).catch((err: Error) => setError(err.message))} />
      </div>
      {error ? <span class="settings-error">{error}</span> : null}
    </li>
  );
}

/** Settings, Sharing: read-only links to this site's stats, each revoked by deleting it. */
export function Sharing({ site }: { site: Site }) {
  const [shares, setShares] = useState<Share[] | null>(null);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState("");
  const load = () =>
    api
      .shares(site.id)
      .then((r) => setShares(r.shares))
      .catch((e: Error) => setError(e.message));
  useEffect(() => {
    void load();
  }, [site.id]);
  const create = (e: Event) => {
    e.preventDefault();
    setError("");
    api
      .createShare(site.id, draft.trim())
      .then(() => {
        setDraft("");
        return load();
      })
      .catch((err: Error) => setError(err.message));
  };
  return (
    <div class="settings-group">
      <p class="settings-text">{t("share.intro")}</p>
      {shares && shares.length ? (
        <ul class="domain-list share-list">
          {shares.map((s) => (
            <ShareRow key={s.id} site={site.id} share={s} home={site.remote ? new URL(site.remote).origin : location.origin} onChanged={() => void load()} />
          ))}
        </ul>
      ) : shares ? (
        <p class="field-hint">{t("share.empty")}</p>
      ) : null}
      <p class="field-hint domain-note">{t("share.revokeNote")}</p>
      <form class="domain-add" onSubmit={create}>
        <input class="value" type="text" maxLength={100} placeholder={t("share.namePlaceholder")} value={draft} onInput={(e) => setDraft((e.target as HTMLInputElement).value)} />
        <button type="submit" class="solid">
          <Icon name="share" />
          {t("share.create")}
        </button>
      </form>
      {error ? <span class="settings-error">{error}</span> : null}
    </div>
  );
}
