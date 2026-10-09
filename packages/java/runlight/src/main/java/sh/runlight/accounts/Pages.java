package sh.runlight.accounts;

import java.util.Map;
import sh.runlight.Js;
import sh.runlight.Version;

/**
 * The account pages: sign in, the code step, invites, and first-run setup. Everything else is the
 * dashboard. Each takes the base path the routes answer under: "" on the standalone server, and
 * "/runlight" in an app. Options are maps with the TypeScript's keys.
 */
public final class Pages {
  private Pages() {}

  private static final String MARK =
      "<svg class=\"mark\" viewBox=\"0 0 32 32\" aria-hidden=\"true\"><rect x=\"2.5\" y=\"2.5\" width=\"27\" height=\"27\" rx=\"7\"/><path d=\"M11 23V9h6.2a4.3 4.3 0 0 1 0 8.6H11m6 0 5 5.4\"/><circle cx=\"23.6\" cy=\"8.4\" r=\"2.6\"/></svg>";

  // Light until someone picks otherwise, as in the dashboard, which shares the choice through
  // localStorage.
  private static final String DARK =
      "color-scheme: dark; --page: #09090b; --card: #141417; --ink: #fafafa; --muted: #a1a1aa; --line: #27272a; --field: #0c0c0e; --bad: #f87171;";

  public static final String AUTH_CSS =
      ":root { color-scheme: light; --page: #f4f4f5; --card: #fff; --ink: #111827; --muted: #6b7280; --line: #e5e7eb; --field: #fff; --bad: #b91c1c; }\n"
          + ":root[data-theme=\"dark\"] { "
          + DARK
          + " }\n"
          + "@media (prefers-color-scheme: dark) { :root[data-theme=\"system\"] { "
          + DARK
          + " } }\n"
          + """
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
          .eye svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }""";

  /**
   * Applies the saved theme before the page paints, then runs the switch and Cmd+Shift+D
   * (Ctrl+Shift+D).
   */
  public static final String AUTH_JS =
      """
      (() => {
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
      })();""";

  private static final String THEME_BUTTON =
      "<button type=\"button\" class=\"theme\" aria-label=\"Switch theme\"><svg data-choice=\"light\" viewBox=\"0 0 16 16\" aria-hidden=\"true\"><circle cx=\"8\" cy=\"8\" r=\"3\"/><path d=\"M8 1.5v1.5M8 13v1.5M1.5 8H3M13 8h1.5M3.4 3.4l1 1M11.6 11.6l1 1M3.4 12.6l1-1M11.6 4.4l1-1\"/></svg><svg data-choice=\"dark\" viewBox=\"0 0 16 16\" aria-hidden=\"true\"><path d=\"M13.5 9.5A5.5 5.5 0 0 1 6.5 2.5a5.5 5.5 0 1 0 7 7z\"/></svg><svg data-choice=\"system\" viewBox=\"0 0 16 16\" aria-hidden=\"true\"><rect x=\"2\" y=\"3\" width=\"12\" height=\"8.5\" rx=\"1.5\"/><path d=\"M5.5 14h5M8 11.5V14\"/></svg></button>";

  private static String esc(String value) {
    StringBuilder out = new StringBuilder(value.length());
    for (int i = 0; i < value.length(); i++) {
      char c = value.charAt(i);
      switch (c) {
        case '&' -> out.append("&amp;");
        case '<' -> out.append("&lt;");
        case '>' -> out.append("&gt;");
        case '"' -> out.append("&quot;");
        case '\'' -> out.append("&#39;");
        default -> out.append(c);
      }
    }
    return out.toString();
  }

  /** opts[key] as text, else the fallback, as {@code opts.key ?? fallback} reads. */
  private static String opt(Map<String, Object> opts, String key, String fallback) {
    Object value = opts.get(key);
    return value == null ? fallback : Js.string(value);
  }

  private static String page(String base, String title, String body) {
    String b = esc(base);
    return "<!doctype html>\n"
        + "<html lang=\"en\">\n"
        + "<head>\n"
        + "<meta charset=\"utf-8\">\n"
        + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        + "<meta name=\"robots\" content=\"noindex\">\n"
        + "<title>"
        + esc(title)
        + " | Runlight</title>\n"
        + "<link rel=\"icon\" href=\""
        + Version.runlightIcon()
        + "\">\n"
        + "<link rel=\"stylesheet\" href=\""
        + b
        + "/auth.css\">\n"
        + "<script src=\""
        + b
        + "/auth.js\"></script>\n"
        + "</head>\n"
        + "<body>\n"
        + "<main>\n"
        + "<p class=\"brand\">"
        + MARK
        + "Runlight</p>\n"
        + body
        + "\n</main>\n"
        + THEME_BUTTON
        + "\n</body>\n"
        + "</html>\n";
  }

  private static String error(Map<String, Object> opts) {
    String error = opt(opts, "error", "");
    return error.isEmpty() ? "" : "<p class=\"error\" role=\"alert\">" + esc(error) + "</p>";
  }

  /** The sign-in page; opts are error, email, next, and forgot. */
  public static String loginPage(String base, Map<String, Object> opts) {
    String b = esc(base);
    return page(
        base,
        "Sign in",
        "<h1>Sign in</h1>\n"
            + "<p>Sign in to see your sites.</p>\n"
            + error(opts)
            + "\n<form method=\"post\" action=\""
            + b
            + "/login\">\n"
            + "<input type=\"hidden\" name=\"next\" value=\""
            + esc(opt(opts, "next", base + "/"))
            + "\">\n"
            + "<label>Email<input type=\"email\" name=\"email\" autocomplete=\"username\" required autofocus value=\""
            + esc(opt(opts, "email", ""))
            + "\"></label>\n"
            + "<label>Password<input type=\"password\" name=\"password\" autocomplete=\"current-password\" required></label>\n"
            + "<button type=\"submit\">Sign in</button>\n"
            + "</form>\n"
            + "<p class=\"hint\">If you have forgotten your password, <a href=\""
            + esc(opt(opts, "forgot", ""))
            + "\" target=\"_blank\" rel=\"noopener\">the docs say how to set a new one</a>.</p>");
  }

  /**
   * The second step of signing in, for an account with two-factor on; opts are pending, next, and
   * error.
   */
  public static String codePage(String base, Map<String, Object> opts) {
    String b = esc(base);
    return page(
        base,
        "Enter your code",
        "<h1>Enter your code</h1>\n"
            + "<p>Open your authenticator app and enter the six-digit code for Runlight.</p>\n"
            + error(opts)
            + "\n<form method=\"post\" action=\""
            + b
            + "/login/code\">\n"
            + "<input type=\"hidden\" name=\"pending\" value=\""
            + esc(opt(opts, "pending", ""))
            + "\">\n"
            + "<input type=\"hidden\" name=\"next\" value=\""
            + esc(opt(opts, "next", ""))
            + "\">\n"
            + "<label>Code<input type=\"text\" name=\"code\" inputmode=\"numeric\" autocomplete=\"one-time-code\" maxlength=\"12\" required autofocus></label>\n"
            + "<button type=\"submit\">Sign in</button>\n"
            + "</form>\n"
            + "<p class=\"hint\">Lost your phone? Enter one of your recovery codes instead. Each works once.</p>");
  }

  /** What someone invited with a role can do, after "as". */
  public static String roleText(String role) {
    if (role.equals("viewer")) {
      return "a viewer, who can read every site's stats";
    }
    if (role.equals("member")) {
      return "a member, who can change the settings of every site";
    }
    return "an admin, who can change everything and manage people";
  }

  /**
   * Where an invited person chooses a password and joins; opts are code, email, role, host, and
   * error.
   */
  public static String invitePage(String base, Map<String, Object> opts) {
    String b = esc(base);
    return page(
        base,
        "Join Runlight",
        "<h1>Join Runlight</h1>\n"
            + "<p>You were invited to "
            + esc(opt(opts, "host", ""))
            + " as "
            + roleText(opt(opts, "role", ""))
            + ". Choose a password to finish.</p>\n"
            + error(opts)
            + "\n<form method=\"post\" action=\""
            + b
            + "/invite\">\n"
            + "<input type=\"hidden\" name=\"code\" value=\""
            + esc(opt(opts, "code", ""))
            + "\">\n"
            + "<label>Email<input type=\"email\" value=\""
            + esc(opt(opts, "email", ""))
            + "\" disabled></label>\n"
            + "<label>Password<input type=\"password\" name=\"password\" autocomplete=\"new-password\" minlength=\"10\" required autofocus></label>\n"
            + "<label>Password again<input type=\"password\" name=\"again\" autocomplete=\"new-password\" minlength=\"10\" required></label>\n"
            + "<button type=\"submit\">Join</button>\n"
            + "</form>\n"
            + "<p class=\"hint\">Use at least ten characters.</p>");
  }

  public static String inviteGonePage(String base) {
    return page(
        base,
        "This invite no longer works",
        "<h1>This invite no longer works</h1>\n"
            + "<p>It has expired or was already used. Ask whoever invited you to send a new one.</p>");
  }

  /** The first account's form; opts are code, error, email, and askCode. */
  public static String setupPage(String base, Map<String, Object> opts) {
    String b = esc(base);
    String code = esc(opt(opts, "code", ""));
    String field =
        Js.truthy(opts.get("askCode"))
            ? "<label>Your RUNLIGHT_TOKEN<input type=\"password\" name=\"code\" autocomplete=\"off\" required value=\""
                + code
                + "\"></label>"
            : "<input type=\"hidden\" name=\"code\" value=\"" + code + "\">";
    return page(
        base,
        "Create your account",
        "<h1>Create your account</h1>\n"
            + "<p>This account owns the dashboard. You can invite more people later in Settings, People.</p>\n"
            + error(opts)
            + "\n<form method=\"post\" action=\""
            + b
            + "/setup\">\n"
            + field
            + "\n<label>Email<input type=\"email\" name=\"email\" autocomplete=\"username\" required autofocus value=\""
            + esc(opt(opts, "email", ""))
            + "\"></label>\n"
            + "<label>Password<input type=\"password\" name=\"password\" autocomplete=\"new-password\" minlength=\"10\" required></label>\n"
            + "<label>Password again<input type=\"password\" name=\"again\" autocomplete=\"new-password\" minlength=\"10\" required></label>\n"
            + "<button type=\"submit\">Create account</button>\n"
            + "</form>\n"
            + "<p class=\"hint\">Use at least ten characters.</p>");
  }

  /**
   * For a server with no account yet, which prints a setup link with a one-time code in its log.
   */
  public static String setupLockedPage(String base) {
    return setupLockedPage(base, null);
  }

  /**
   * As {@link #setupLockedPage(String)}, saying where the setup link is when it is not in a log
   * (HTML).
   */
  public static String setupLockedPage(String base, String where) {
    String at = where == null ? "printed in the server's log when it started" : where;
    return page(
        base,
        "Finish setting up",
        "<h1>Finish setting up</h1>\n"
            + "<p>Runlight has no account yet. Open the setup link "
            + at
            + ", which carries a one-time code, to create the first account.</p>");
  }

  /** For an app with accounts on but nothing to prove the first account with. */
  public static String setupNeedsTokenPage(String base) {
    return page(
        base,
        "Finish setting up",
        "<h1>Finish setting up</h1>\n"
            + "<p>Runlight has no account yet. Set RUNLIGHT_TOKEN, or pass token to routes(), and open this page again. Creating the first account asks for it, so only whoever runs the app can.</p>");
  }
}
