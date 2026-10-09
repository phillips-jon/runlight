defmodule Runlight.Accounts.Pages do
  @moduledoc false
  # Internal. The account pages: sign in, the code step, invites, and
  # first-run setup (the SDK's accounts/pages.ts). Everything else is the
  # dashboard. Each takes the base path the routes answer under: "" on a
  # standalone server, and "/runlight" in an app. Options are maps with atom
  # keys: error, email, next, forgot, pending, code, role, host, and ask_code.

  alias Runlight.Assets
  alias Runlight.JS

  @css ":root { color-scheme: light; --page: #f4f4f5; --card: #fff; --ink: #111827; --muted: #6b7280; --line: #e5e7eb; --field: #fff; --bad: #b91c1c; }\n:root[data-theme=\"dark\"] { color-scheme: dark; --page: #09090b; --card: #141417; --ink: #fafafa; --muted: #a1a1aa; --line: #27272a; --field: #0c0c0e; --bad: #f87171; }\n@media (prefers-color-scheme: dark) { :root[data-theme=\"system\"] { color-scheme: dark; --page: #09090b; --card: #141417; --ink: #fafafa; --muted: #a1a1aa; --line: #27272a; --field: #0c0c0e; --bad: #f87171; } }\n* { box-sizing: border-box; }\nbody { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px 16px; background: var(--page); color: var(--ink); font: 15px/1.5 -apple-system, BlinkMacSystemFont, \"Segoe UI\", Helvetica, Arial, sans-serif; }\nmain { width: min(400px, 100%); padding: 28px; border: 1px solid var(--line); border-radius: 14px; background: var(--card); }\n.brand { display: flex; align-items: center; gap: 9px; margin: 0 0 22px; color: var(--ink); font-weight: 700; font-size: 16px; }\n.mark { width: 26px; height: 26px; }\n.mark rect { fill: var(--ink); }\n.mark path { fill: none; stroke: var(--card); stroke-width: 2.8; stroke-linecap: round; stroke-linejoin: round; }\n.mark circle { fill: #22c55e; }\nh1 { margin: 0 0 6px; font-size: 21px; }\np { margin: 0 0 18px; color: var(--muted); }\nlabel { display: block; margin: 0 0 14px; font-size: 13px; font-weight: 600; }\ninput { display: block; width: 100%; height: 40px; margin-top: 6px; padding: 0 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--field); color: var(--ink); font: inherit; }\ninput:focus { outline: 2px solid #2a78d6; outline-offset: -1px; }\nmain button { width: 100%; height: 40px; margin-top: 6px; border: 0; border-radius: 8px; background: var(--ink); color: var(--card); font: inherit; font-weight: 600; cursor: pointer; }\n.error { margin: 0 0 14px; color: var(--bad); font-size: 14px; }\n.hint { margin: 16px 0 0; font-size: 13px; }\n.hint a { color: var(--ink); }\n.theme { position: fixed; right: 16px; bottom: 16px; display: grid; place-items: center; width: 34px; height: 34px; padding: 0; border: 1px solid var(--line); border-radius: 8px; background: var(--card); color: var(--muted); cursor: pointer; }\n.theme:hover { color: var(--ink); }\n.theme svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }\n.theme svg:not(.on) { display: none; }\n.secret { position: relative; display: block; margin-top: 6px; }\n.secret input { margin-top: 0; padding-right: 44px; }\n.eye { position: absolute; top: 50%; right: 5px; display: grid; place-items: center; width: 32px; height: 30px; margin: 0; padding: 0; border: 0; border-radius: 6px; background: none; color: var(--muted); transform: translateY(-50%); cursor: pointer; }\nmain .eye { width: 32px; height: 30px; margin: 0; background: none; color: var(--muted); }\n.eye:hover, .eye[aria-pressed=\"true\"] { color: var(--ink); }\n.eye svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }"
  @js "(() => {\n  const KEY = \"runlight_theme\";\n  const root = document.documentElement;\n  const read = () => { try { const v = localStorage.getItem(KEY); return v === \"dark\" || v === \"system\" ? v : \"light\"; } catch { return \"light\"; } };\n  const dark = () => { const c = read(); return c === \"system\" ? matchMedia(\"(prefers-color-scheme: dark)\").matches : c === \"dark\"; };\n  const show = () => {\n    const c = read();\n    root.dataset.theme = c;\n    const button = document.querySelector(\".theme\");\n    if (!button) return;\n    for (const icon of button.querySelectorAll(\"svg\")) icon.classList.toggle(\"on\", icon.dataset.choice === c);\n    button.title = c === \"system\" ? \"Theme: device setting\" : \"Theme: \" + c;\n  };\n  const set = (c) => { try { localStorage.setItem(KEY, c); } catch {} show(); };\n  show();\n  const EYE = '<svg viewBox=\"0 0 16 16\" aria-hidden=\"true\"><path d=\"M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8s-2.4 4.5-6.5 4.5S1.5 8 1.5 8zM8 6a2 2 0 1 0 0 4 2 2 0 0 0 0-4z\"/></svg>';\n  const SHUT = '<svg viewBox=\"0 0 16 16\" aria-hidden=\"true\"><path d=\"M1.5 8s2.4-4.5 6.5-4.5c1 0 1.9.3 2.7.7M14.5 8s-2.4 4.5-6.5 4.5c-1 0-1.9-.3-2.7-.7M6.6 6.6a2 2 0 0 0 2.8 2.8M2.5 2.5l11 11\"/></svg>';\n  document.addEventListener(\"DOMContentLoaded\", () => {\n    // An eye button in each password field, to show what was typed.\n    for (const input of document.querySelectorAll('input[type=\"password\"]')) {\n      const wrap = document.createElement(\"span\");\n      wrap.className = \"secret\";\n      input.replaceWith(wrap);\n      wrap.append(input);\n      const eye = document.createElement(\"button\");\n      eye.type = \"button\";\n      eye.className = \"eye\";\n      const set = (shown) => {\n        input.type = shown ? \"text\" : \"password\";\n        eye.setAttribute(\"aria-pressed\", String(shown));\n        eye.setAttribute(\"aria-label\", shown ? \"Hide password\" : \"Show password\");\n        eye.title = shown ? \"Hide password\" : \"Show password\";\n        eye.innerHTML = shown ? SHUT : EYE;\n      };\n      set(false);\n      eye.addEventListener(\"click\", () => set(input.type === \"password\"));\n      wrap.append(eye);\n    }\n    show();\n    document.querySelector(\".theme\")?.addEventListener(\"click\", () => set({ light: \"dark\", dark: \"system\", system: \"light\" }[read()]));\n  });\n  document.addEventListener(\"keydown\", (e) => {\n    if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === \"d\") { e.preventDefault(); set(dark() ? \"light\" : \"dark\"); }\n  });\n})();"
  @mark "<svg class=\"mark\" viewBox=\"0 0 32 32\" aria-hidden=\"true\"><rect x=\"2.5\" y=\"2.5\" width=\"27\" height=\"27\" rx=\"7\"/><path d=\"M11 23V9h6.2a4.3 4.3 0 0 1 0 8.6H11m6 0 5 5.4\"/><circle cx=\"23.6\" cy=\"8.4\" r=\"2.6\"/></svg>"
  @theme_button "<button type=\"button\" class=\"theme\" aria-label=\"Switch theme\"><svg data-choice=\"light\" viewBox=\"0 0 16 16\" aria-hidden=\"true\"><circle cx=\"8\" cy=\"8\" r=\"3\"/><path d=\"M8 1.5v1.5M8 13v1.5M1.5 8H3M13 8h1.5M3.4 3.4l1 1M11.6 11.6l1 1M3.4 12.6l1-1M11.6 4.4l1-1\"/></svg><svg data-choice=\"dark\" viewBox=\"0 0 16 16\" aria-hidden=\"true\"><path d=\"M13.5 9.5A5.5 5.5 0 0 1 6.5 2.5a5.5 5.5 0 1 0 7 7z\"/></svg><svg data-choice=\"system\" viewBox=\"0 0 16 16\" aria-hidden=\"true\"><rect x=\"2\" y=\"3\" width=\"12\" height=\"8.5\" rx=\"1.5\"/><path d=\"M5.5 14h5M8 11.5V14\"/></svg></button>"

  @doc "The pages' stylesheet."
  def auth_css, do: @css

  @doc "Applies the saved theme before the page paints, then runs the switch and Cmd+Shift+D (Ctrl+Shift+D)."
  def auth_js, do: @js

  defp esc(value), do: JS.escape_html(value || "")

  defp page(base, title, body) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex">
    <title>#{esc(title)} | Runlight</title>
    <link rel="icon" href="#{Assets.icon()}">
    <link rel="stylesheet" href="#{esc(base)}/auth.css">
    <script src="#{esc(base)}/auth.js"></script>
    </head>
    <body>
    <main>
    <p class="brand">#{@mark}Runlight</p>
    #{body}
    </main>
    #{@theme_button}
    </body>
    </html>
    """
  end

  defp error_line(opts) do
    case opts[:error] do
      e when e in [nil, ""] -> ""
      e -> ~s(<p class="error" role="alert">#{esc(e)}</p>)
    end
  end

  def login_page(base, opts) do
    page(
      base,
      "Sign in",
      "<h1>Sign in</h1>\n<p>Sign in to see your sites.</p>\n" <>
        error_line(opts) <>
        "\n" <>
        ~s(<form method="post" action="#{esc(base)}/login">\n) <>
        ~s(<input type="hidden" name="next" value="#{esc(opts[:next] || "#{base}/")}">\n) <>
        ~s(<label>Email<input type="email" name="email" autocomplete="username" required autofocus value="#{esc(opts[:email] || "")}"></label>\n) <>
        ~s(<label>Password<input type="password" name="password" autocomplete="current-password" required></label>\n) <>
        ~s(<button type="submit">Sign in</button>\n</form>\n) <>
        ~s(<p class="hint">If you have forgotten your password, <a href="#{esc(opts[:forgot])}" target="_blank" rel="noopener">the docs say how to set a new one</a>.</p>)
    )
  end

  @doc "The second step of signing in, for an account with two-factor on."
  def code_page(base, opts) do
    page(
      base,
      "Enter your code",
      "<h1>Enter your code</h1>\n<p>Open your authenticator app and enter the six-digit code for Runlight.</p>\n" <>
        error_line(opts) <>
        "\n" <>
        ~s(<form method="post" action="#{esc(base)}/login/code">\n) <>
        ~s(<input type="hidden" name="pending" value="#{esc(opts[:pending])}">\n) <>
        ~s(<input type="hidden" name="next" value="#{esc(opts[:next])}">\n) <>
        ~s(<label>Code<input type="text" name="code" inputmode="numeric" autocomplete="one-time-code" maxlength="12" required autofocus></label>\n) <>
        ~s(<button type="submit">Sign in</button>\n</form>\n) <>
        ~s(<p class="hint">Lost your phone? Enter one of your recovery codes instead. Each works once.</p>)
    )
  end

  @doc "What someone invited with a role can do, after \"as\"."
  def role_text("viewer"), do: "a viewer, who can read every site's stats"
  def role_text("member"), do: "a member, who can change the settings of every site"
  def role_text(_), do: "an admin, who can change everything and manage people"

  @doc "Where an invited person chooses a password and joins."
  def invite_page(base, opts) do
    page(
      base,
      "Join Runlight",
      "<h1>Join Runlight</h1>\n" <>
        "<p>You were invited to #{esc(opts[:host])} as #{role_text(opts[:role])}. Choose a password to finish.</p>\n" <>
        error_line(opts) <>
        "\n" <>
        ~s(<form method="post" action="#{esc(base)}/invite">\n) <>
        ~s(<input type="hidden" name="code" value="#{esc(opts[:code])}">\n) <>
        ~s(<label>Email<input type="email" value="#{esc(opts[:email])}" disabled></label>\n) <>
        ~s(<label>Password<input type="password" name="password" autocomplete="new-password" minlength="10" required autofocus></label>\n) <>
        ~s(<label>Password again<input type="password" name="again" autocomplete="new-password" minlength="10" required></label>\n) <>
        ~s(<button type="submit">Join</button>\n</form>\n) <>
        ~s(<p class="hint">Use at least ten characters.</p>)
    )
  end

  def invite_gone_page(base) do
    page(
      base,
      "This invite no longer works",
      "<h1>This invite no longer works</h1>\n<p>It has expired or was already used. Ask whoever invited you to send a new one.</p>"
    )
  end

  def setup_page(base, opts) do
    code_field =
      if opts[:ask_code],
        do:
          ~s(<label>Your RUNLIGHT_TOKEN<input type="password" name="code" autocomplete="off" required value="#{esc(opts[:code])}"></label>),
        else: ~s(<input type="hidden" name="code" value="#{esc(opts[:code])}">)

    page(
      base,
      "Create your account",
      "<h1>Create your account</h1>\n<p>This account owns the dashboard. You can invite more people later in Settings, People.</p>\n" <>
        error_line(opts) <>
        "\n" <>
        ~s(<form method="post" action="#{esc(base)}/setup">\n) <>
        code_field <>
        "\n" <>
        ~s(<label>Email<input type="email" name="email" autocomplete="username" required autofocus value="#{esc(opts[:email] || "")}"></label>\n) <>
        ~s(<label>Password<input type="password" name="password" autocomplete="new-password" minlength="10" required></label>\n) <>
        ~s(<label>Password again<input type="password" name="again" autocomplete="new-password" minlength="10" required></label>\n) <>
        ~s(<button type="submit">Create account</button>\n</form>\n) <>
        ~s(<p class="hint">Use at least ten characters.</p>)
    )
  end

  @doc "For a server with no account yet, which prints a setup link with a one-time code in its log."
  def setup_locked_page(base) do
    page(
      base,
      "Finish setting up",
      "<h1>Finish setting up</h1>\n<p>Runlight has no account yet. Open the setup link printed in the server's log when it started, which carries a one-time code, to create the first account.</p>"
    )
  end

  @doc "For an app with accounts on but nothing to prove the first account with."
  def setup_needs_token_page(base) do
    page(
      base,
      "Finish setting up",
      "<h1>Finish setting up</h1>\n<p>Runlight has no account yet. Set RUNLIGHT_TOKEN, or pass token to routes(), and open this page again. Creating the first account asks for it, so only whoever runs the app can.</p>"
    )
  end
end
