import { useEffect, useState } from "preact/hooks";
import { api, type InviteSent, type PendingInvite, type Person } from "./api.js";
import { day } from "./format.js";
import { t, type Key } from "./i18n.js";
import { Secret } from "./secret.js";
import { Icon } from "./icons.js";
import { DeleteButton, Sheet } from "./links.js";
import { strength } from "./strength.js";
import { Code } from "./settings.js";

const dateOf = (ms: number) => day(new Date(ms).toISOString().slice(0, 10));

/** Your own account on the standalone server: who you are, and a new password. */
export function AccountSheet({ me, onClose }: { me: Person; onClose: () => void }) {
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [again, setAgain] = useState("");
  const score = strength(next, [me.email.split("@")[0]!, me.email]);
  const mismatch = again.length > 0 && again !== next;
  const [state, setState] = useState<"idle" | "saving" | "saved">("idle");
  const [error, setError] = useState("");
  const save = (e: Event) => {
    e.preventDefault();
    setState("saving");
    setError("");
    api
      .changePassword(current, next)
      .then(() => {
        setState("saved");
        setCurrent("");
        setNext("");
        setAgain("");
      })
      .catch((err: Error) => {
        setError(err.message);
        setState("idle");
      });
  };
  return (
    <Sheet title={t("account.title")} sub={me.email} onClose={onClose}>
      <form class="sheet-body link-form" onSubmit={save}>
        <p class="settings-text">{t(me.role === "owner" ? "account.owner" : "account.viewer")}</p>
        <label class="field-row">
          <span class="field-label">{t("account.current")}</span>
          <Secret class="value" autoComplete="current-password" required value={current} onInput={(e) => setCurrent((e.target as HTMLInputElement).value)} />
        </label>
        <label class="field-row">
          <span class="field-label">{t("account.next")}</span>
          <Secret class="value" autoComplete="new-password" minLength={10} required value={next} onInput={(e) => setNext((e.target as HTMLInputElement).value)} aria-describedby="password-strength" />
          {next ? (
            <span class="strength" id="password-strength" data-score={score} aria-live="polite">
              <span class="strength-bar" aria-hidden="true">
                {[1, 2, 3, 4].map((n) => (
                  <span class={score >= n ? "on" : ""} />
                ))}
              </span>
              <span class="strength-label">{t(`account.strength${score}` as Key)}</span>
            </span>
          ) : null}
          <span class="field-hint">{t("account.nextHint")}</span>
        </label>
        <label class="field-row">
          <span class="field-label">{t("account.again")}</span>
          <Secret class="value" autoComplete="new-password" required value={again} aria-invalid={mismatch} onInput={(e) => setAgain((e.target as HTMLInputElement).value)} />
          {mismatch ? <span class="field-hint field-bad">{t("account.mismatch")}</span> : null}
        </label>
        <div class="settings-actions">
          {error ? <span class="settings-error">{error}</span> : null}
          {state === "saved" ? <span class="settings-ok">{t("account.saved")}</span> : null}
          <button type="submit" class="solid" disabled={state === "saving" || !current || next.length < 10 || again !== next}>
            <Icon name="save" />
            {t("account.save")}
          </button>
        </div>
      </form>
    </Sheet>
  );
}

/** Settings, People: everyone who can sign in, their role, and adding or removing someone. */
export function People({ me }: { me: Person }) {
  const [people, setPeople] = useState<Person[] | null>(null);
  const [invites, setInvites] = useState<PendingInvite[]>([]);
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<Person["role"]>("viewer");
  const [sent, setSent] = useState<InviteSent | null>(null);
  const [error, setError] = useState("");
  const load = () =>
    api
      .people()
      .then((r) => {
        setPeople(r.people);
        setInvites(r.invites ?? []);
      })
      .catch((e: Error) => setError(e.message));
  useEffect(() => {
    void load();
  }, []);
  const done = (r: InviteSent) => {
    setSent(r);
    return load();
  };
  const add = (e: Event) => {
    e.preventDefault();
    setError("");
    api
      .addPerson(email.trim(), role)
      .then((r) => {
        setEmail("");
        return done(r);
      })
      .catch((err: Error) => setError(err.message));
  };
  const change = (id: string, next: Person["role"]) =>
    api
      .setRole(id, next)
      .then(load)
      .catch((err: Error) => setError(err.message));
  return (
    <div class="settings-group">
      <p class="settings-text">{t("people.intro")}</p>
      {sent ? (
        <div class="token-made">
          <p class="settings-text">
            {sent.emailed
              ? t("people.emailed", { email: sent.invite.email })
              : sent.mailError
                ? t("people.mailFailed", { email: sent.invite.email, error: sent.mailError })
                : t("people.noMail", { email: sent.invite.email })}
          </p>
          <div class="invite-link">
            <Code>{sent.link}</Code>
          </div>
          <p class="field-hint">{t("people.linkHint")}</p>
          <button type="button" class="ghost token-done" onClick={() => setSent(null)}>
            <Icon name="check" />
            {t("tokens.done")}
          </button>
        </div>
      ) : null}
      {people ? (
        <ul class="domain-list share-list">
          {people.map((p) => (
            <li key={p.id}>
              <div class="domain-main">
                <span class="share-name">
                  {p.email}
                  {p.id === me.id ? <span class="people-you">{t("people.you")}</span> : null}
                </span>
                <span class="share-meta">{t("links.createdOn", { date: dateOf(p.createdAt) })}</span>
              </div>
              <div class="domain-actions">
                <select class="value people-role" value={p.role} aria-label={t("people.role")} onChange={(e) => void change(p.id, (e.target as HTMLSelectElement).value as Person["role"])}>
                  <option value="owner">{t("people.owner")}</option>
                  <option value="viewer">{t("people.viewer")}</option>
                </select>
                {p.id === me.id ? null : (
                  <DeleteButton
                    name={p.email}
                    onDelete={() =>
                      void api
                        .removePerson(p.id)
                        .then(load)
                        .catch((err: Error) => setError(err.message))
                    }
                  />
                )}
              </div>
            </li>
          ))}
          {invites.map((i) => (
            <li key={i.id} class="invited">
              <div class="domain-main">
                <span class="share-name">
                  {i.email}
                  <span class="people-you">{t("people.invited")}</span>
                </span>
                <span class="share-meta">{t("people.invitedMeta", { role: t(i.role === "owner" ? "people.owner" : "people.viewer"), date: dateOf(i.expiresAt) })}</span>
              </div>
              <div class="domain-actions">
                <button type="button" class="copy inline" onClick={() => void api.resendInvite(i.id).then(done).catch((err: Error) => setError(err.message))}>
                  <Icon name="send" />
                  {t("people.resend")}
                </button>
                <DeleteButton name={i.email} onDelete={() => void api.cancelInvite(i.id).then(load).catch((err: Error) => setError(err.message))} />
              </div>
            </li>
          ))}
        </ul>
      ) : null}
      <p class="field-hint domain-note">{t("people.roles")}</p>
      <form class="domain-add token-add" onSubmit={add}>
        <input class="value" type="email" required placeholder={t("people.emailPlaceholder")} value={email} onInput={(e) => setEmail((e.target as HTMLInputElement).value)} />
        <select class="value" value={role} aria-label={t("people.role")} onChange={(e) => setRole((e.target as HTMLSelectElement).value as Person["role"])}>
          <option value="viewer">{t("people.viewer")}</option>
          <option value="owner">{t("people.owner")}</option>
        </select>
        <button type="submit" class="solid">
          <Icon name="send" />
          {t("people.invite")}
        </button>
      </form>
      {error ? <span class="settings-error">{error}</span> : null}
    </div>
  );
}
