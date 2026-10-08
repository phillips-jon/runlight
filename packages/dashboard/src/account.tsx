import { useEffect, useState } from "preact/hooks";
import { api, type InviteSent, type PendingInvite, type Person } from "./api.js";
import { day } from "./format.js";
import { t, type Key } from "./i18n.js";
import { Secret } from "./secret.js";
import { Icon } from "./icons.js";
import { DeleteButton, Sheet } from "./links.js";
import { strength } from "./strength.js";
import { Code } from "./settings.js";
import { qrSvg } from "./qr.js";

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
        <div class="settings-actions start">
          <button type="submit" class="solid" disabled={state === "saving" || !current || next.length < 10 || again !== next}>
            <Icon name="save" />
            {t("account.save")}
          </button>
          {state === "saved" ? <span class="settings-ok">{t("account.saved")}</span> : null}
          {error ? <span class="settings-error">{error}</span> : null}
        </div>
      </form>
      <TwoFactor me={me} />
    </Sheet>
  );
}

/** Account, Two-factor sign-in: turning it on with a QR code, recovery codes, and turning it off. */
function TwoFactor({ me }: { me: Person }) {
  const [on, setOn] = useState(Boolean(me.twoFactor));
  const [left, setLeft] = useState(me.recoveryLeft ?? 0);
  // asking: which action wants the password first; setup: the secret to scan; codes: recovery codes to show once.
  const [asking, setAsking] = useState<"start" | "recovery" | "disable" | null>(null);
  const [password, setPassword] = useState("");
  const [setup, setSetup] = useState<{ secret: string; uri: string } | null>(null);
  const [code, setCode] = useState("");
  const [codes, setCodes] = useState<string[] | null>(null);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const run = <T,>(work: Promise<T>, then: (r: T) => void) => {
    setError("");
    setBusy(true);
    work
      .then(then)
      .catch((err: Error) => setError(err.message))
      .finally(() => setBusy(false));
  };
  const confirmPassword = (e: Event) => {
    e.preventDefault();
    if (asking === "start") run(api.twoFactorStart(password), (r) => {
      setSetup(r);
      setAsking(null);
      setPassword("");
    });
    if (asking === "recovery") run(api.twoFactorRecovery(password), (r) => {
      setCodes(r.recovery);
      setLeft(r.recovery.length);
      setAsking(null);
      setPassword("");
    });
    if (asking === "disable") run(api.twoFactorDisable(password), () => {
      setOn(false);
      setAsking(null);
      setPassword("");
    });
  };
  const confirmCode = (e: Event) => {
    e.preventDefault();
    run(api.twoFactorConfirm(code), (r) => {
      setCodes(r.recovery);
      setLeft(r.recovery.length);
      setOn(true);
      setSetup(null);
      setCode("");
    });
  };
  const qr = setup ? qrSvg(setup.uri) : null;
  const saveCodes = () => {
    const blob = new Blob([`Runlight recovery codes for ${me.email}\n\n${codes!.join("\n")}\n\nEach code works once.\n`], { type: "text/plain" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = "runlight-recovery-codes.txt";
    link.click();
    URL.revokeObjectURL(link.href);
  };

  return (
    <div class="sheet-body link-form twofactor">
      <div class="field-row">
        <span class="field-label">{t("twofa.title")}</span>
        <span class="field-hint">{on ? t(left === 1 ? "twofa.on_one" : "twofa.on_other", { n: left }) : t("twofa.off")}</span>
      </div>
      {codes ? (
        <div class="token-made">
          <p class="settings-text">{t("twofa.codesIntro")}</p>
          <ol class="recovery-codes">
            {codes.map((c) => (
              <li>
                <code>{c}</code>
              </li>
            ))}
          </ol>
          <div class="settings-actions start">
            <button type="button" class="ghost" onClick={saveCodes}>
              <Icon name="download" />
              {t("twofa.download")}
            </button>
            <button type="button" class="ghost" onClick={() => void navigator.clipboard?.writeText(codes.join("\n")).then(() => setCopied(true)).catch(() => {})}>
              <Icon name={copied ? "check" : "copy"} />
              {t(copied ? "install.copied" : "twofa.copy")}
            </button>
            <button type="button" class="solid" onClick={() => setCodes(null)}>
              <Icon name="check" />
              {t("twofa.saved")}
            </button>
          </div>
        </div>
      ) : setup && qr ? (
        <form class="twofactor-setup" onSubmit={confirmCode}>
          <p class="settings-text">{t("twofa.scan")}</p>
          <div class="qr">
            <svg viewBox={`0 0 ${qr.size} ${qr.size}`} role="img" aria-label={t("twofa.qr")} shape-rendering="crispEdges">
              <rect width={qr.size} height={qr.size} fill="#ffffff" />
              <path d={qr.path} fill="#000000" />
            </svg>
          </div>
          <p class="field-hint">{t("twofa.manual")}</p>
          <Code>{setup.secret.replace(/(.{4})/g, "$1 ").trim()}</Code>
          <label class="field-row">
            <span class="field-label">{t("twofa.code")}</span>
            <input class="value" type="text" inputmode="numeric" autoComplete="one-time-code" maxLength={7} required value={code} onInput={(e) => setCode((e.target as HTMLInputElement).value)} />
          </label>
          <div class="settings-actions start">
            <button type="submit" class="solid" disabled={busy || code.replace(/\s/g, "").length !== 6}>
              <Icon name="check" />
              {t("twofa.confirm")}
            </button>
            <button
              type="button"
              class="ghost"
              onClick={() => {
                setSetup(null);
                setError("");
              }}
            >
              {t("common.cancel")}
            </button>
          </div>
        </form>
      ) : asking ? (
        <form class="twofactor-setup" onSubmit={confirmPassword}>
          <label class="field-row">
            <span class="field-label">{t("twofa.password")}</span>
            <Secret class="value" autoComplete="current-password" required value={password} onInput={(e) => setPassword((e.target as HTMLInputElement).value)} />
          </label>
          <div class="settings-actions start">
            <button type="submit" class={asking === "disable" ? "solid danger" : "solid"} disabled={busy || !password}>
              <Icon name={asking === "disable" ? "x" : "check"} />
              {t(asking === "start" ? "twofa.continue" : asking === "recovery" ? "twofa.newCodes" : "twofa.turnOff")}
            </button>
            <button
              type="button"
              class="ghost"
              onClick={() => {
                setAsking(null);
                setError("");
              }}
            >
              {t("common.cancel")}
            </button>
          </div>
        </form>
      ) : (
        <div class="settings-actions start">
          {on ? (
            <>
              <button type="button" class="ghost" onClick={() => setAsking("recovery")}>
                <Icon name="refresh" />
                {t("twofa.newCodes")}
              </button>
              <button type="button" class="ghost" onClick={() => setAsking("disable")}>
                <Icon name="x" />
                {t("twofa.turnOff")}
              </button>
            </>
          ) : (
            <button type="button" class="solid" onClick={() => setAsking("start")}>
              <Icon name="key" />
              {t("twofa.turnOn")}
            </button>
          )}
        </div>
      )}
      {error ? <p class="settings-error">{error}</p> : null}
    </div>
  );
}

/** Resetting someone's two-factor takes a second click, like deleting. */
function ResetTwoFactor({ onReset }: { onReset: () => void }) {
  const [armed, setArmed] = useState(false);
  useEffect(() => {
    if (!armed) return;
    const timer = setTimeout(() => setArmed(false), 4000);
    return () => clearTimeout(timer);
  }, [armed]);
  return (
    <button type="button" class={armed ? "copy inline armed" : "copy inline"} title={t("people.resetTwoFactorHint")} onClick={() => (armed ? onReset() : setArmed(true))}>
      <Icon name="reset" />
      {armed ? t("links.confirm") : t("people.resetTwoFactor")}
    </button>
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
  // While an invite is on its way, its buttons wait, so a double click sends one.
  const [sending, setSending] = useState(false);
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
    setSending(true);
    api
      .addPerson(email.trim(), role)
      .then((r) => {
        setEmail("");
        return done(r);
      })
      .catch((err: Error) => setError(err.message))
      .finally(() => setSending(false));
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
                  {p.twoFactor ? <span class="people-you">{t("people.twoFactor")}</span> : null}
                </span>
                <span class="share-meta">{t("links.createdOn", { date: dateOf(p.createdAt) })}</span>
              </div>
              <div class="domain-actions">
                {p.twoFactor && p.id !== me.id ? (
                  <ResetTwoFactor onReset={() => void api.resetTwoFactor(p.id).then(load).catch((err: Error) => setError(err.message))} />
                ) : null}
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
                <button
                  type="button"
                  class="copy inline"
                  disabled={sending}
                  onClick={() => {
                    setSending(true);
                    void api
                      .resendInvite(i.id)
                      .then(done)
                      .catch((err: Error) => setError(err.message))
                      .finally(() => setSending(false));
                  }}
                >
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
        <button type="submit" class="solid" disabled={sending}>
          <Icon name="send" />
          {t("people.invite")}
        </button>
      </form>
      {error ? <span class="settings-error">{error}</span> : null}
    </div>
  );
}
