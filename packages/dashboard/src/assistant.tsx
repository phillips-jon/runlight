import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { api, type AssistantProvider, type AssistantState, type Site, type View } from "./api.js";
import { currentLocale, t, tn } from "./i18n.js";
import { Secret } from "./secret.js";
import { Callout } from "./callout.js";
import { Icon } from "./icons.js";
import { DeleteButton } from "./links.js";
import { useDialogFocus } from "./focus.js";

interface Message {
  role: "user" | "assistant";
  content: string;
  /** How many reports the assistant read for this answer. */
  checked?: number;
  error?: boolean;
}

/** What is on screen, in words the model can use: the dates and any filters. */
function describeView(view: View): string {
  const dates = view.from && view.to ? `${view.from} to ${view.to}` : `the period "${view.period}"`;
  const filters = view.filters.map((f) => `${f.dimension} ${f.op} ${f.value}`).join(", ");
  return filters ? `${dates}, filtered to ${filters}` : dates;
}

/** Inline **bold** and `code`, as nodes, never as HTML. */
function inline(text: string): ComponentChildren[] {
  const out: ComponentChildren[] = [];
  const pattern = /\*\*([^*]+)\*\*|`([^`]+)`/g;
  let at = 0;
  for (let m = pattern.exec(text); m; m = pattern.exec(text)) {
    if (m.index > at) out.push(text.slice(at, m.index));
    out.push(m[1] !== undefined ? <strong>{m[1]}</strong> : <code>{m[2]}</code>);
    at = m.index + m[0].length;
  }
  if (at < text.length) out.push(text.slice(at));
  return out;
}

/** The little Markdown models write: paragraphs, bullet and numbered lists, and simple tables. */
function Reply({ text }: { text: string }) {
  const blocks: ComponentChildren[] = [];
  const lines = text.replace(/\r/g, "").split("\n");
  for (let i = 0; i < lines.length; ) {
    const line = lines[i]!;
    if (!line.trim()) {
      i++;
      continue;
    }
    if (/^\s*[-*] /.test(line) || /^\s*\d+[.)] /.test(line)) {
      const ordered = /^\s*\d/.test(line);
      const items: string[] = [];
      while (i < lines.length && (/^\s*[-*] /.test(lines[i]!) || /^\s*\d+[.)] /.test(lines[i]!))) items.push(lines[i++]!.replace(/^\s*(?:[-*]|\d+[.)]) /, ""));
      blocks.push(ordered ? <ol>{items.map((x) => <li>{inline(x)}</li>)}</ol> : <ul>{items.map((x) => <li>{inline(x)}</li>)}</ul>);
      continue;
    }
    if (line.trim().startsWith("|")) {
      const rows: string[][] = [];
      while (i < lines.length && lines[i]!.trim().startsWith("|")) {
        const cells = lines[i++]!.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
        if (!cells.every((c) => /^:?-{2,}:?$/.test(c))) rows.push(cells);
      }
      const [head, ...body] = rows;
      blocks.push(
        <div class="reply-table">
          <table>
            {head ? <thead><tr>{head.map((c) => <th>{inline(c)}</th>)}</tr></thead> : null}
            <tbody>{body.map((r) => <tr>{r.map((c) => <td>{inline(c)}</td>)}</tr>)}</tbody>
          </table>
        </div>,
      );
      continue;
    }
    const para: string[] = [];
    while (i < lines.length && lines[i]!.trim() && !/^\s*(?:[-*]|\d+[.)]) /.test(lines[i]!) && !lines[i]!.trim().startsWith("|")) para.push(lines[i++]!.replace(/^#+\s*/, ""));
    blocks.push(<p>{inline(para.join(" "))}</p>);
  }
  return <div class="reply">{blocks}</div>;
}

const SUGGESTIONS = ["assistant.ask1", "assistant.ask2", "assistant.ask3", "assistant.ask4"] as const;

/** The chat drawer, opened from the robot button beside Filter. */
export function AssistantDrawer({ site, view, owner, onSetup, onClose }: { site: Site; view: View; owner: boolean; onSetup: () => void; onClose: () => void }) {
  const key = `runlight_assistant:${site.id}`;
  const dialog = useRef<HTMLDivElement>(null);
  useDialogFocus(dialog);
  const [state, setState] = useState<AssistantState | null>(null);
  const [messages, setMessages] = useState<Message[]>(() => {
    try {
      const saved = JSON.parse(sessionStorage.getItem(key) ?? "[]") as Message[];
      // A question left without its answer (the drawer closed while it was asked) is dropped, not asked twice.
      while (saved.length && saved[saved.length - 1]!.role === "user") saved.pop();
      return saved;
    } catch {
      return [];
    }
  });
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const list = useRef<HTMLDivElement>(null);
  // Bumped by New chat, so an answer to a question from before it is not put back.
  const chat = useRef(0);
  const input = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    void api.assistant().then(setState).catch(() => setState({ configured: false }));
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    document.addEventListener("keydown", onKey);
    document.body.classList.add("locked");
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.classList.remove("locked");
    };
  }, []);
  useEffect(() => {
    try {
      sessionStorage.setItem(key, JSON.stringify(messages.slice(-40)));
    } catch {}
    list.current?.scrollTo({ top: list.current.scrollHeight, behavior: "smooth" });
  }, [messages, busy]);
  useEffect(() => {
    if (state?.configured) input.current?.focus();
  }, [state?.configured]);

  const ask = (question: string) => {
    const text = question.trim();
    if (!text || busy) return;
    const next: Message[] = [...messages, { role: "user", content: text }];
    setMessages(next);
    setDraft("");
    setBusy(true);
    const asked = chat.current;
    api
      .ask(site.id, next.filter((m) => !m.error).map(({ role, content }) => ({ role, content })), describeView(view), currentLocale())
      .then((r) => asked === chat.current && setMessages([...next, { role: "assistant", content: r.reply || t("assistant.empty"), checked: r.tools.length }]))
      .catch((err: Error) => asked === chat.current && setMessages([...next, { role: "assistant", content: err.message, error: true }]))
      .finally(() => asked === chat.current && setBusy(false));
  };

  return (
    <div class="scrim" onPointerDown={(e) => e.target === e.currentTarget && onClose()}>
      <div class="drawer assistant" role="dialog" aria-modal="true" aria-labelledby="assistant-title" ref={dialog}>
        <header class="drawer-head">
          <h2 id="assistant-title">{t("assistant.title")}</h2>
          <div class="assistant-tools">
            {messages.length ? (
              <button
                type="button"
                class="copy inline"
                onClick={() => {
                  chat.current++;
                  setBusy(false);
                  setMessages([]);
                }}
              >
                <Icon name="reset" />
                {t("assistant.clear")}
              </button>
            ) : null}
            <button type="button" class="remove" aria-label={t("common.close")} onClick={onClose}>
              <svg viewBox="0 0 16 16" aria-hidden="true">
                <path d="M4 4l8 8M12 4l-8 8" />
              </svg>
            </button>
          </div>
        </header>
        <p class="assistant-about">{t("assistant.about", { site: site.name })}</p>
        <div class="drawer-body assistant-messages" ref={list} aria-live="polite">
          {state && !state.configured ? (
            <div class="assistant-empty">
              <span class="assistant-mark" aria-hidden="true">
                <Icon name="robot" />
              </span>
              <p>{t(owner ? "assistant.setupOwner" : "assistant.setupViewer")}</p>
              {owner ? (
                <button type="button" class="solid" onClick={onSetup}>
                  <Icon name="key" />
                  {t("assistant.setup")}
                </button>
              ) : null}
            </div>
          ) : messages.length === 0 ? (
            <div class="assistant-empty">
              <span class="assistant-mark" aria-hidden="true">
                <Icon name="robot" />
              </span>
              <p>{t("assistant.intro")}</p>
              <div class="assistant-suggestions">
                {SUGGESTIONS.map((k) => (
                  <button type="button" class="ghost" disabled={!state} onClick={() => ask(t(k))}>
                    {t(k)}
                  </button>
                ))}
              </div>
            </div>
          ) : (
            messages.map((m) => (
              <div class={`message ${m.role}${m.error ? " error" : ""}`}>
                {m.role === "user" ? <p>{m.content}</p> : <Reply text={m.content} />}
                {m.checked ? <span class="message-meta">{tn("assistant.checked", m.checked)}</span> : null}
              </div>
            ))
          )}
          {busy ? (
            <div class="message assistant thinking">
              <span class="dots" role="status" aria-label={t("assistant.thinking")}>
                <span />
                <span />
                <span />
              </span>
            </div>
          ) : null}
        </div>
        {state?.configured ? (
          <form
            class="drawer-foot assistant-ask"
            onSubmit={(e) => {
              e.preventDefault();
              ask(draft);
            }}
          >
            <textarea
              ref={input}
              class="value"
              rows={2}
              aria-label={t("assistant.placeholder")}
              placeholder={t("assistant.placeholder")}
              value={draft}
              onInput={(e) => setDraft((e.target as HTMLTextAreaElement).value)}
              onKeyDown={(e) => {
                // Enter sends; Shift+Enter starts a new line.
                if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                  e.preventDefault();
                  ask(draft);
                }
              }}
            />
            <button type="submit" class="solid" disabled={busy || !draft.trim()} aria-label={t("assistant.send")}>
              <Icon name="send" />
            </button>
          </form>
        ) : null}
      </div>
    </div>
  );
}

/** Settings, AI Assistant: the provider, model, and key the assistant uses, set by an owner. */
export function AssistantSettings({ owner }: { owner: boolean }) {
  const [state, setState] = useState<AssistantState | null>(null);
  const [form, setForm] = useState({ provider: "anthropic", model: "", baseUrl: "", key: "" });
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);
  const [models, setModels] = useState<Array<{ id: string; name: string }> | null>(null);
  const [typing, setTyping] = useState(false);
  const [loading, setLoading] = useState(false);
  const [modelError, setModelError] = useState("");
  const [daily, setDaily] = useState("");
  const [dailyState, setDailyState] = useState<{ saved?: boolean; error?: string }>({});
  const loadModels = () => {
    setModelError("");
    setLoading(true);
    api
      .assistantModels({ provider: form.provider, baseUrl: form.baseUrl, key: form.key })
      .then((r) => {
        setModels(r.models);
        setTyping(false);
        // Keep a model already chosen; otherwise start on the service's default, or the first listed.
        if (!form.model) setForm((f) => ({ ...f, model: r.models.some((m) => m.id === chosen?.model) ? chosen!.model : (r.models[0]?.id ?? "") }));
      })
      .catch((err: Error) => setModelError(err.message))
      .finally(() => setLoading(false));
  };
  const load = () =>
    api
      .assistant()
      .then((s) => {
        setState(s);
        setForm({ provider: s.provider || "anthropic", model: s.model ?? "", baseUrl: s.baseUrl ?? "", key: "" });
        setDaily(String(s.viewerDaily ?? ""));
      })
      .catch((e: Error) => setError(e.message));
  useEffect(() => {
    void load();
  }, []);
  if (!owner) return <p class="settings-text">{t("assistant.ownersOnly")}</p>;
  if (!state) return error ? <p class="settings-error">{error}</p> : null;
  const providers = state.providers ?? [];
  const chosen: AssistantProvider | undefined = providers.find((p) => p.id === form.provider);
  const sameProvider = state.provider === form.provider;

  const save = (e: Event) => {
    e.preventDefault();
    setError("");
    setSaved(false);
    setBusy(true);
    api
      .saveAssistant(form)
      .then(() => {
        setSaved(true);
        return load();
      })
      .catch((err: Error) => setError(err.message))
      .finally(() => setBusy(false));
  };

  return (
    <>
      <div class="settings-group">
        <p class="settings-text">{t("assistant.settingsIntro")}</p>
        <Callout icon="eye" title={t("assistant.privacyTitle")}>
          {t("assistant.privacy")}
        </Callout>
        {!state.encrypted ? (
          <Callout icon="key" tone="warn" title={t("assistant.notEncryptedTitle")}>
            {t("assistant.notEncrypted")}
          </Callout>
        ) : null}
      </div>
      <form class="settings-group" onSubmit={save}>
        <label class="field-row">
          <span class="field-label">{t("assistant.provider")}</span>
          <select
            class="value"
            value={form.provider}
            onChange={(e) => {
              const id = (e.target as HTMLSelectElement).value;
              setForm({ provider: id, model: id === state.provider ? (state.model ?? "") : "", baseUrl: id === state.provider ? (state.baseUrl ?? "") : "", key: "" });
              setModels(null);
              setModelError("");
              setSaved(false);
            }}
          >
            {providers.map((p) => (
              <option value={p.id}>{p.name}</option>
            ))}
          </select>
        </label>
        {chosen && (chosen.key !== "yes" || !chosen.baseUrl) ? (
          <label class="field-row">
            <span class="field-label">{t("assistant.address")}</span>
            <input class="value" type="url" placeholder={chosen.baseUrl || "https://api.example.com/v1"} value={form.baseUrl} onInput={(e) => setForm({ ...form, baseUrl: (e.target as HTMLInputElement).value })} />
            <span class="field-hint">{t(chosen.key === "no" ? "assistant.addressLocal" : "assistant.addressHint")}</span>
          </label>
        ) : null}
        {chosen?.key !== "no" ? (
          <label class="field-row">
            <span class="field-label">{t("assistant.key")}</span>
            <Secret
              class="value"
              autoComplete="off"
              placeholder={sameProvider && state.keySaved ? t("mail.keepSaved") : ""}
              value={form.key}
              onInput={(e) => setForm({ ...form, key: (e.target as HTMLInputElement).value })}
            />
          </label>
        ) : null}
        {/* The model comes last: load the service's own list with the key above, or type a name. */}
        <div class="field-row">
          <span class="field-label">{t("assistant.model")}</span>
          <div class="model-row">
            {models && !typing ? (
              <select class="value" value={form.model} onChange={(e) => setForm({ ...form, model: (e.target as HTMLSelectElement).value })}>
                {!form.model ? <option value="">{t("assistant.pickModel")}</option> : null}
                {form.model && !models.some((m) => m.id === form.model) ? <option value={form.model}>{form.model}</option> : null}
                {models.map((m) => (
                  <option value={m.id}>{m.name === m.id ? m.id : `${m.name} (${m.id})`}</option>
                ))}
              </select>
            ) : (
              <input class="value" type="text" spellcheck={false} aria-label={t("assistant.model")} placeholder={chosen?.model || t("assistant.modelPlaceholder")} value={form.model} onInput={(e) => setForm({ ...form, model: (e.target as HTMLInputElement).value })} />
            )}
            <button type="button" class="ghost" disabled={loading} onClick={loadModels}>
              <Icon name="refresh" />
              {t(loading ? "assistant.loadingModels" : "assistant.loadModels")}
            </button>
          </div>
          {models ? (
            <button type="button" class="text-button" onClick={() => setTyping(!typing)}>
              {t(typing ? "assistant.chooseFromList" : "assistant.typeModel")}
            </button>
          ) : (
            <span class="field-hint">{chosen?.model ? t("assistant.modelDefault", { model: chosen.model }) : t("assistant.modelHint")}</span>
          )}
          {modelError ? <span class="settings-error">{modelError}</span> : null}
        </div>
        <div class="settings-actions">
          <button type="submit" class="solid" disabled={busy}>
            <Icon name="save" />
            {t("settings.save")}
          </button>
          {saved ? <span class="settings-ok">{t("settings.saved")}</span> : null}
          {error ? <span class="settings-error">{error}</span> : null}
        </div>
      </form>
      {state.configured ? (
        <form
          class="settings-group"
          onSubmit={(e) => {
            e.preventDefault();
            setDailyState({});
            api
              .saveAssistantLimit(Number(daily))
              .then(() => setDailyState({ saved: true }))
              .catch((err: Error) => setDailyState({ error: err.message }));
          }}
        >
          <label class="field-row">
            <span class="field-label">{t("assistant.viewerDaily")}</span>
            <input class="value" type="number" min={0} max={1000} step={1} required value={daily} onInput={(e) => setDaily((e.target as HTMLInputElement).value)} />
            <span class="field-hint">{t("assistant.viewerDailyHint")}</span>
          </label>
          <div class="settings-actions">
            <button type="submit" class="solid">
              <Icon name="save" />
              {t("settings.save")}
            </button>
            {dailyState.saved ? <span class="settings-ok">{t("settings.saved")}</span> : null}
            {dailyState.error ? <span class="settings-error">{dailyState.error}</span> : null}
          </div>
        </form>
      ) : null}
      {state.configured ? (
        <div class="settings-group">
          <div class="field-row">
            <span class="field-label">{t("assistant.remove")}</span>
            <span class="field-hint">{t("assistant.removeHint")}</span>
            <div>
              <DeleteButton name={chosen?.name ?? ""} onDelete={() => void api.removeAssistant().then(load)} />
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}
