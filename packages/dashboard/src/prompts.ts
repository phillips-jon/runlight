/**
 * Setup instructions to paste into a coding assistant, filled in with this
 * install's real addresses. Kept in English whatever the dashboard's language,
 * since that is what coding assistants follow best.
 */

export function domainPrompt(opts: { domain: string; host: string; origin: string; base: string; linkPath: string }): string {
  const { domain, host, origin, base, linkPath } = opts;
  return `Set up a custom short link domain for Runlight, the analytics in this project.

Runlight's dashboard runs at ${origin}${base}. Short links are served by this app at ${origin}${linkPath}/<slug>. I want them also served at the root of ${domain}, like https://${domain}/<slug>.

Please do these steps, and tell me anything I have to do by hand:

1. DNS. Tell me the record to add at my DNS provider: a CNAME for ${domain} pointing to ${host}. If ${domain} has no subdomain, it needs an A or ALIAS record to the same server instead.

2. Hosting. Make this app accept requests for ${domain} over HTTPS. On Vercel or Netlify, that means adding ${domain} to the project's domains. On my own server, add it to the web server config (for nginx: a server_name and a certificate, for example with certbot) and proxy it to the app the same way as the main domain.

3. App. In the app's middleware (proxy.ts in Next.js 16, middleware.ts before it), answer requests for link domains before anything else:

   import { rl } from "@/lib/runlight";

   export async function proxy(request: Request) {
     const link = await rl.linkDomainResponse(request);
     if (link) return link;
     // ...whatever the middleware already does
   }

   Keep any middleware that is already there; this goes first. It returns null for every other host, so the rest of the site is unaffected.

4. Check. https://${domain}/.well-known/runlight-link-domain should answer {"runlight":true,"domain":"${domain}"}. Once it does, ${domain} shows as Working under Settings, Custom domains in the Runlight dashboard (add it there if it is not listed yet).

Do not change anything else about how links or analytics work.
`;
}

/** For a site counted by a standalone Runlight server: only the script tag goes on the site. */
export function scriptPrompt(opts: { script: string; host?: string }): string {
  return `Add Runlight, privacy friendly web analytics, to this site${opts.host ? ` (${opts.host})` : ""}.

Add this script tag to every page, just before </head>, in the shared layout or template so it is on every page:

   ${opts.script}

Runlight sets no cookies and stores no personal data, so do not add a cookie banner for it. To count a custom event, add data-runlight="Event name" to an element, or call runlight("Event name") in JavaScript.

Keep the site's existing behaviour unchanged otherwise.
`;
}

export function installPrompt(opts: { origin: string; base: string; site?: string }): string {
  const { origin, base, site } = opts;
  return `Add Runlight, privacy friendly web analytics, to this project.

The dashboard should live at ${base} on this site (it is at ${origin}${base} here).

1. Install the package: npm install @runlight/sdk (and better-sqlite3 for a SQLite file, or pg for Postgres; use Postgres on Vercel or anywhere without a persistent disk).

2. Create lib/runlight.ts:

   import { runlight } from "@runlight/sdk";
   import { sqlite } from "@runlight/sdk/sqlite";
   export const rl = runlight({ store: sqlite({ path: "./data/runlight.db" }) });

   For Postgres: import { postgres } from "@runlight/sdk/postgres" and use postgres({ url: process.env.DATABASE_URL }).

3. Mount the routes. In Next.js, app${base}/[[...path]]/route.ts:

   import { rl } from "@/lib/runlight";
   export const { GET, POST, PUT, PATCH, DELETE, OPTIONS } = rl.routes(${base === "/runlight" ? "" : `{ basePath: "${base}" }`});

   For Express or plain Node, use toNodeHandler(rl.routes().handler) from "@runlight/sdk/node".

4. Short links: app/go/[slug]/route.ts with export const GET = rl.linkHandler();

5. Add the tracker to every page, just before </head>:

   <script defer src="${base}/s.js"${site ? ` data-site="${site}"` : ""}></script>

6. Set RUNLIGHT_TOKEN to a long random string in the environment; open ${base}?token=<that string> once to sign in to the dashboard.

7. Optional, to see AI agents like ChatGPT and Claude reading pages: in the middleware (proxy.ts in Next.js 16), call void rl.observe(request) for every request.

Keep the site's existing behaviour unchanged otherwise.
`;
}
