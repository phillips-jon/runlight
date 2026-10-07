/** The server's own pages: sign in and first-run setup. Everything else is the SDK's dashboard. */
import { RUNLIGHT_ICON } from "@runlight/sdk";

const esc = (value: string) => value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

const MARK = `<svg class="mark" viewBox="0 0 32 32" aria-hidden="true"><rect x="2.5" y="2.5" width="27" height="27" rx="7"/><path d="M11 23V9h6.2a4.3 4.3 0 0 1 0 8.6H11m6 0 5 5.4"/><circle cx="23.6" cy="8.4" r="2.6"/></svg>`;

export const AUTH_CSS = `:root { color-scheme: light dark; --page: #f4f4f5; --card: #fff; --ink: #111827; --muted: #6b7280; --line: #e5e7eb; --field: #fff; --bad: #b91c1c; }
@media (prefers-color-scheme: dark) { :root { --page: #09090b; --card: #141417; --ink: #fafafa; --muted: #a1a1aa; --line: #27272a; --field: #0c0c0e; --bad: #f87171; } }
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
button { width: 100%; height: 40px; margin-top: 6px; border: 0; border-radius: 8px; background: var(--ink); color: var(--card); font: inherit; font-weight: 600; cursor: pointer; }
.error { margin: 0 0 14px; color: var(--bad); font-size: 14px; }
.hint { margin: 16px 0 0; font-size: 13px; }`;

function page(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${esc(title)} | Runlight</title>
<link rel="icon" href="${RUNLIGHT_ICON}">
<link rel="stylesheet" href="/auth.css">
</head>
<body>
<main>
<p class="brand">${MARK}Runlight</p>
${body}
</main>
</body>
</html>
`;
}

export function loginPage(opts: { error?: string; email?: string; next?: string }): string {
  return page(
    "Sign in",
    `<h1>Sign in</h1>
<p>Sign in to see your sites.</p>
${opts.error ? `<p class="error" role="alert">${esc(opts.error)}</p>` : ""}
<form method="post" action="/login">
<input type="hidden" name="next" value="${esc(opts.next ?? "/")}">
<label>Email<input type="email" name="email" autocomplete="username" required autofocus value="${esc(opts.email ?? "")}"></label>
<label>Password<input type="password" name="password" autocomplete="current-password" required></label>
<button type="submit">Sign in</button>
</form>
<p class="hint">If you have forgotten your password, run <code>npx runlight.sh password you@example.com</code> on the server to set a new one.</p>`,
  );
}

export function setupPage(opts: { code: string; error?: string; email?: string }): string {
  return page(
    "Create your account",
    `<h1>Create your account</h1>
<p>This account signs in to the dashboard. You can add more people later from the server.</p>
${opts.error ? `<p class="error" role="alert">${esc(opts.error)}</p>` : ""}
<form method="post" action="/setup">
<input type="hidden" name="code" value="${esc(opts.code)}">
<label>Email<input type="email" name="email" autocomplete="username" required autofocus value="${esc(opts.email ?? "")}"></label>
<label>Password<input type="password" name="password" autocomplete="new-password" minlength="10" required></label>
<button type="submit">Create account</button>
</form>`,
  );
}

export function setupLockedPage(): string {
  return page(
    "Finish setting up",
    `<h1>Finish setting up</h1>
<p>Runlight has no account yet. Open the setup link printed in the server's log when it started, which carries a one-time code, to create the first account.</p>`,
  );
}
