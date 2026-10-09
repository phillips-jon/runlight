//! The account pages: sign in, the code step, invites, and first-run setup. Everything else is the dashboard.
//! Each takes the base path the routes answer under: "" on the standalone server, and "/runlight" in an app.

use crate::brand::RUNLIGHT_ICON;

/// Text made safe for HTML, quotes included.
fn esc(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            other => out.push(other),
        }
    }
    out
}

const MARK: &str = r#"<svg class="mark" viewBox="0 0 32 32" aria-hidden="true"><rect x="2.5" y="2.5" width="27" height="27" rx="7"/><path d="M11 23V9h6.2a4.3 4.3 0 0 1 0 8.6H11m6 0 5 5.4"/><circle cx="23.6" cy="8.4" r="2.6"/></svg>"#;

/// The account pages' styles, light until someone picks otherwise, as in the dashboard, which shares the
/// choice through localStorage.
pub const AUTH_CSS: &str = r#":root { color-scheme: light; --page: #f4f4f5; --card: #fff; --ink: #111827; --muted: #6b7280; --line: #e5e7eb; --field: #fff; --bad: #b91c1c; }
:root[data-theme="dark"] { color-scheme: dark; --page: #09090b; --card: #141417; --ink: #fafafa; --muted: #a1a1aa; --line: #27272a; --field: #0c0c0e; --bad: #f87171; }
@media (prefers-color-scheme: dark) { :root[data-theme="system"] { color-scheme: dark; --page: #09090b; --card: #141417; --ink: #fafafa; --muted: #a1a1aa; --line: #27272a; --field: #0c0c0e; --bad: #f87171; } }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px 16px; background: var(--page); color: var(--ink); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
main { width: min(400px, 100%); padding: 28px; border: 1px solid var(--line); border-radius: 14px; background: var(--card); }
.brand { display: flex; align-items: center; gap: 9px; margin: 0 0 22px; color: var(--ink); font-weight: 700; font-size: 16px; }
.mark { width: 26px; height: 26px; }
.mark rect { fill: var(--ink); }
.mark path { fill: none; stroke: var(--card); stroke-width: 2.8; stroke-linecap: round; stroke-linejoin: round; }
.mark circle { fill: #22c55e; }
h1 { margin: 0 0 6px; font-size: 21px; }
p { margin: 0 0 18px; color: var(--muted); }
label { display: block; margin: 0 0 14px; font-size: 13px; font-weight: 600; }
input { display: block; width: 100%; height: 40px; margin-top: 6px; padding: 0 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--field); color: var(--ink); font: inherit; }
input:focus { outline: 2px solid #2a78d6; outline-offset: -1px; }
main button { width: 100%; height: 40px; margin-top: 6px; border: 0; border-radius: 8px; background: var(--ink); color: var(--card); font: inherit; font-weight: 600; cursor: pointer; }
.error { margin: 0 0 14px; color: var(--bad); font-size: 14px; }
.hint { margin: 16px 0 0; font-size: 13px; }
.hint a { color: var(--ink); }
.theme { position: fixed; right: 16px; bottom: 16px; display: grid; place-items: center; width: 34px; height: 34px; padding: 0; border: 1px solid var(--line); border-radius: 8px; background: var(--card); color: var(--muted); cursor: pointer; }
.theme:hover { color: var(--ink); }
.theme svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }
.theme svg:not(.on) { display: none; }
.secret { position: relative; display: block; margin-top: 6px; }
.secret input { margin-top: 0; padding-right: 44px; }
.eye { position: absolute; top: 50%; right: 5px; display: grid; place-items: center; width: 32px; height: 30px; margin: 0; padding: 0; border: 0; border-radius: 6px; background: none; color: var(--muted); transform: translateY(-50%); cursor: pointer; }
main .eye { width: 32px; height: 30px; margin: 0; background: none; color: var(--muted); }
.eye:hover, .eye[aria-pressed="true"] { color: var(--ink); }
.eye svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }"#;

/// Applies the saved theme before the page paints, then runs the switch and Cmd+Shift+D (Ctrl+Shift+D).
pub const AUTH_JS: &str = r#"(() => {
  const KEY = "runlight_theme";
  const root = document.documentElement;
  const read = () => { try { const v = localStorage.getItem(KEY); return v === "dark" || v === "system" ? v : "light"; } catch { return "light"; } };
  const dark = () => { const c = read(); return c === "system" ? matchMedia("(prefers-color-scheme: dark)").matches : c === "dark"; };
  const show = () => {
    const c = read();
    root.dataset.theme = c;
    const button = document.querySelector(".theme");
    if (!button) return;
    for (const icon of button.querySelectorAll("svg")) icon.classList.toggle("on", icon.dataset.choice === c);
    button.title = c === "system" ? "Theme: device setting" : "Theme: " + c;
  };
  const set = (c) => { try { localStorage.setItem(KEY, c); } catch {} show(); };
  show();
  const EYE = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8s-2.4 4.5-6.5 4.5S1.5 8 1.5 8zM8 6a2 2 0 1 0 0 4 2 2 0 0 0 0-4z"/></svg>';
  const SHUT = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M1.5 8s2.4-4.5 6.5-4.5c1 0 1.9.3 2.7.7M14.5 8s-2.4 4.5-6.5 4.5c-1 0-1.9-.3-2.7-.7M6.6 6.6a2 2 0 0 0 2.8 2.8M2.5 2.5l11 11"/></svg>';
  document.addEventListener("DOMContentLoaded", () => {
    // An eye button in each password field, to show what was typed.
    for (const input of document.querySelectorAll('input[type="password"]')) {
      const wrap = document.createElement("span");
      wrap.className = "secret";
      input.replaceWith(wrap);
      wrap.append(input);
      const eye = document.createElement("button");
      eye.type = "button";
      eye.className = "eye";
      const set = (shown) => {
        input.type = shown ? "text" : "password";
        eye.setAttribute("aria-pressed", String(shown));
        eye.setAttribute("aria-label", shown ? "Hide password" : "Show password");
        eye.title = shown ? "Hide password" : "Show password";
        eye.innerHTML = shown ? SHUT : EYE;
      };
      set(false);
      eye.addEventListener("click", () => set(input.type === "password"));
      wrap.append(eye);
    }
    show();
    document.querySelector(".theme")?.addEventListener("click", () => set({ light: "dark", dark: "system", system: "light" }[read()]));
  });
  document.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "d") { e.preventDefault(); set(dark() ? "light" : "dark"); }
  });
})();"#;

const THEME_BUTTON: &str = r#"<button type="button" class="theme" aria-label="Switch theme"><svg data-choice="light" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="3"/><path d="M8 1.5v1.5M8 13v1.5M1.5 8H3M13 8h1.5M3.4 3.4l1 1M11.6 11.6l1 1M3.4 12.6l1-1M11.6 4.4l1-1"/></svg><svg data-choice="dark" viewBox="0 0 16 16" aria-hidden="true"><path d="M13.5 9.5A5.5 5.5 0 0 1 6.5 2.5a5.5 5.5 0 1 0 7 7z"/></svg><svg data-choice="system" viewBox="0 0 16 16" aria-hidden="true"><rect x="2" y="3" width="12" height="8.5" rx="1.5"/><path d="M5.5 14h5M8 11.5V14"/></svg></button>"#;

fn page(base: &str, title: &str, body: &str) -> String {
    let base = esc(base);
    format!(
        r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{title} | Runlight</title>
<link rel="icon" href="{RUNLIGHT_ICON}">
<link rel="stylesheet" href="{base}/auth.css">
<script src="{base}/auth.js"></script>
</head>
<body>
<main>
<p class="brand">{MARK}Runlight</p>
{body}
</main>
{THEME_BUTTON}
</body>
</html>
"#,
        title = esc(title)
    )
}

/// An error paragraph, or nothing for no error or an empty one.
fn error_line(error: Option<&str>) -> String {
    match error {
        Some(e) if !e.is_empty() => format!(r#"<p class="error" role="alert">{}</p>"#, esc(e)),
        _ => String::new(),
    }
}

/// What the sign-in page shows.
#[derive(Clone, Debug, Default)]
pub struct LoginPage<'a> {
    /// Why the last try failed.
    pub error: Option<&'a str>,
    /// The address typed before.
    pub email: Option<&'a str>,
    /// Where to go once signed in; the dashboard when `None`.
    pub next: Option<&'a str>,
    /// The docs page on setting a new password.
    pub forgot: &'a str,
}

/// The sign-in page.
pub fn login_page(base: &str, opts: &LoginPage<'_>) -> String {
    let next = opts.next.map_or_else(|| format!("{base}/"), str::to_string);
    page(
        base,
        "Sign in",
        &format!(
            r#"<h1>Sign in</h1>
<p>Sign in to see your sites.</p>
{error}
<form method="post" action="{b}/login">
<input type="hidden" name="next" value="{next}">
<label>Email<input type="email" name="email" autocomplete="username" required autofocus value="{email}"></label>
<label>Password<input type="password" name="password" autocomplete="current-password" required></label>
<button type="submit">Sign in</button>
</form>
<p class="hint">If you have forgotten your password, <a href="{forgot}" target="_blank" rel="noopener">the docs say how to set a new one</a>.</p>"#,
            error = error_line(opts.error),
            b = esc(base),
            next = esc(&next),
            email = esc(opts.email.unwrap_or("")),
            forgot = esc(opts.forgot),
        ),
    )
}

/// What the code step shows.
#[derive(Clone, Debug, Default)]
pub struct CodePage<'a> {
    /// The signed ticket naming the account that still owes a code.
    pub pending: &'a str,
    /// Where to go once signed in.
    pub next: &'a str,
    /// Why the last code failed.
    pub error: Option<&'a str>,
}

/// The second step of signing in, for an account with two-factor on.
pub fn code_page(base: &str, opts: &CodePage<'_>) -> String {
    page(
        base,
        "Enter your code",
        &format!(
            r#"<h1>Enter your code</h1>
<p>Open your authenticator app and enter the six-digit code for Runlight.</p>
{error}
<form method="post" action="{b}/login/code">
<input type="hidden" name="pending" value="{pending}">
<input type="hidden" name="next" value="{next}">
<label>Code<input type="text" name="code" inputmode="numeric" autocomplete="one-time-code" maxlength="12" required autofocus></label>
<button type="submit">Sign in</button>
</form>
<p class="hint">Lost your phone? Enter one of your recovery codes instead. Each works once.</p>"#,
            error = error_line(opts.error),
            b = esc(base),
            pending = esc(opts.pending),
            next = esc(opts.next),
        ),
    )
}

/// What someone invited with a role can do, after "as".
pub fn role_text(role: &str) -> &'static str {
    match role {
        "viewer" => "a viewer, who can read every site's stats",
        "member" => "a member, who can change the settings of every site",
        _ => "an admin, who can change everything and manage people",
    }
}

/// What the invite page shows.
#[derive(Clone, Debug, Default)]
pub struct InvitePage<'a> {
    /// The code from the invite's link.
    pub code: &'a str,
    /// Who it is for.
    pub email: &'a str,
    /// The role they join with.
    pub role: &'a str,
    /// The server's host, as they know it.
    pub host: &'a str,
    /// Why the last try failed.
    pub error: Option<&'a str>,
}

/// Where an invited person chooses a password and joins.
pub fn invite_page(base: &str, opts: &InvitePage<'_>) -> String {
    page(
        base,
        "Join Runlight",
        &format!(
            r#"<h1>Join Runlight</h1>
<p>You were invited to {host} as {role}. Choose a password to finish.</p>
{error}
<form method="post" action="{b}/invite">
<input type="hidden" name="code" value="{code}">
<label>Email<input type="email" value="{email}" disabled></label>
<label>Password<input type="password" name="password" autocomplete="new-password" minlength="10" required autofocus></label>
<label>Password again<input type="password" name="again" autocomplete="new-password" minlength="10" required></label>
<button type="submit">Join</button>
</form>
<p class="hint">Use at least ten characters.</p>"#,
            host = esc(opts.host),
            role = role_text(opts.role),
            error = error_line(opts.error),
            b = esc(base),
            code = esc(opts.code),
            email = esc(opts.email),
        ),
    )
}

/// For an invite link that has expired or was used.
pub fn invite_gone_page(base: &str) -> String {
    page(
        base,
        "This invite no longer works",
        r#"<h1>This invite no longer works</h1>
<p>It has expired or was already used. Ask whoever invited you to send a new one.</p>"#,
    )
}

/// What the setup page shows.
#[derive(Clone, Debug, Default)]
pub struct SetupPage<'a> {
    /// The one-time code, or the token typed before.
    pub code: &'a str,
    /// Why the last try failed.
    pub error: Option<&'a str>,
    /// The address typed before.
    pub email: Option<&'a str>,
    /// Whether to ask for RUNLIGHT_TOKEN rather than carry a code from the link.
    pub ask_code: bool,
}

/// Where the first account is made.
pub fn setup_page(base: &str, opts: &SetupPage<'_>) -> String {
    let code = if opts.ask_code {
        format!(
            r#"<label>Your RUNLIGHT_TOKEN<input type="password" name="code" autocomplete="off" required value="{}"></label>"#,
            esc(opts.code)
        )
    } else {
        format!(r#"<input type="hidden" name="code" value="{}">"#, esc(opts.code))
    };
    page(
        base,
        "Create your account",
        &format!(
            r#"<h1>Create your account</h1>
<p>This account owns the dashboard. You can invite more people later in Settings, People.</p>
{error}
<form method="post" action="{b}/setup">
{code}
<label>Email<input type="email" name="email" autocomplete="username" required autofocus value="{email}"></label>
<label>Password<input type="password" name="password" autocomplete="new-password" minlength="10" required></label>
<label>Password again<input type="password" name="again" autocomplete="new-password" minlength="10" required></label>
<button type="submit">Create account</button>
</form>
<p class="hint">Use at least ten characters.</p>"#,
            error = error_line(opts.error),
            b = esc(base),
            email = esc(opts.email.unwrap_or("")),
        ),
    )
}

/// For a server with no account yet, which prints a setup link with a one-time code in its log.
pub fn setup_locked_page(base: &str) -> String {
    page(
        base,
        "Finish setting up",
        r#"<h1>Finish setting up</h1>
<p>Runlight has no account yet. Open the setup link printed in the server's log when it started, which carries a one-time code, to create the first account.</p>"#,
    )
}

/// For an app with accounts on but nothing to prove the first account with.
pub fn setup_needs_token_page(base: &str) -> String {
    page(
        base,
        "Finish setting up",
        r#"<h1>Finish setting up</h1>
<p>Runlight has no account yet. Set RUNLIGHT_TOKEN, or pass token to routes(), and open this page again. Creating the first account asks for it, so only whoever runs the app can.</p>"#,
    )
}
