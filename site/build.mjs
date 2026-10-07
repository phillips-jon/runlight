/**
 * Builds runlight.sh into dist/: the landing page from src/landing.html, a
 * page per markdown file in docs/, the prompt for coding agents (prompt.txt
 * and llms.txt), and hashed copies of the stylesheet and script.
 *
 *   node build.mjs            build once
 *   node build.mjs --serve    build, watch, and serve on http://localhost:4330
 *   node build.mjs --check    build into a temporary folder and check every link
 */
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, watch, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { marked } from "marked";

const here = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(here, "src");
const DOCS = path.join(here, "docs");
const args = process.argv.slice(2);
const CHECK = args.includes("--check");
const SERVE = args.includes("--serve");
const DIST = CHECK ? mkdtempSync(path.join(tmpdir(), "runlight-site-")) : path.join(here, "dist");
const SITE = "https://runlight.sh";
const GITHUB = "https://github.com/phillips-jon/runlight";
const PORT = Number(process.env.PORT ?? 4330);

const escape = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const slug = (s) => s.toLowerCase().replace(/<[^>]+>/g, "").replace(/&#?[a-z0-9]+;/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const digest = (text) => createHash("sha256").update(text).digest("hex").slice(0, 10);

function frontmatter(text) {
  const m = /^---\n([\s\S]*?)\n---\n?/.exec(text);
  if (!m) return { meta: {}, body: text };
  const meta = {};
  for (const line of m[1].split("\n")) {
    const i = line.indexOf(":");
    if (i > 0) meta[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^"|"$/g, "");
  }
  return { meta, body: text.slice(m[0].length) };
}

/** Light syntax colour for the languages the docs use: strings, comments, and keywords. */
function highlight(code, lang) {
  const esc = escape(code);
  if (!["ts", "tsx", "js", "jsx", "json", "bash", "sh", "html"].includes(lang)) return esc;
  const tokens = [];
  const stash = (html) => `\u0000${tokens.push(html) - 1}\u0000`;
  const shell = lang === "bash" || lang === "sh";
  const comment = lang === "html" ? /&lt;!--[\s\S]*?--&gt;/.source : shell ? /(?<=^|\s)#[^\n]*/.source : /(?<=^|\s)\/\/[^\n]*/.source;
  const string = /&quot;(?:[^&]|&(?!quot;))*?&quot;|'[^'\n]*'|`[^`]*`/.source;
  let out = esc.replace(new RegExp(`(${comment})|${string}`, "gm"), (m, c) => stash(`<span class="${c ? "c" : "s"}">${m}</span>`));
  if (!shell && lang !== "html" && lang !== "json") {
    out = out.replace(/\b(import|export|from|const|let|async|await|return|function|new|if|else|type|interface|default|null|true|false)\b/g, '<span class="k">$1</span>');
  }
  return out.replace(/\u0000(\d+)\u0000/g, (m, i) => tokens[Number(i)]);
}

let headingIds = new Set();
const pageToc = [];
marked.use({
  gfm: true,
  renderer: {
    heading({ tokens, depth }) {
      const text = this.parser.parseInline(tokens);
      let id = slug(text);
      for (let n = 1; headingIds.has(id); n++) id = `${slug(text)}-${n}`;
      headingIds.add(id);
      if (depth === 2) pageToc.push({ id, text });
      return `<h${depth} id="${id}"><a class="anchor" href="#${id}">${text}</a></h${depth}>\n`;
    },
    code({ text, lang }) {
      const [language = "text", ...rest] = (lang || "").trim().split(/\s+/);
      const file = rest.find((r) => r.startsWith("file="))?.slice(5);
      return `<div class="out"><p class="from"><span>${escape(file ?? language)}</span><button type="button" class="copy">Copy</button></p><pre><code translate="no">${highlight(text, language)}</code></pre></div>\n`;
    },
    table(token) {
      return `<div class="table">${new marked.Renderer().table.call(this, token)}</div>\n`;
    },
  },
});

/** Curly apostrophes in prose, never in code or attributes. */
const curly = (html) =>
  html.split(/(<pre[\s\S]*?<\/pre>|<code[\s\S]*?<\/code>|<[^>]+>)/).map((part, i) => (i % 2 ? part : part.replace(/(\w)(?:'|&#39;)(\w)/g, "$1’$2"))).join("");

/** The mark: an R in a rounded lamp housing, one corner lit. The R is cut
    from the housing in the sheet's colour, so it follows the theme. */
const MARK = `<svg class="mark" viewBox="0 0 32 32" aria-hidden="true" focusable="false"><rect class="housing" x="2.5" y="2.5" width="27" height="27" rx="7"/><path class="r" d="M11 23V9h6.2a4.3 4.3 0 0 1 0 8.6H11m6 0 5 5.4"/><circle class="lit" cx="23.6" cy="8.4" r="2.6"/></svg>`;
const FAVICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><style>.h{fill:#000}.r{stroke:#fff}@media (prefers-color-scheme:dark){.h{fill:#fff}.r{stroke:#000}}</style><rect class="h" x="2.5" y="2.5" width="27" height="27" rx="7"/><path class="r" d="M11 23V9h6.2a4.3 4.3 0 0 1 0 8.6H11m6 0 5 5.4" fill="none" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/><circle cx="23.6" cy="8.4" r="2.6" fill="#22c55e"/></svg>`;

const THEME_ICONS = `<svg class="moon" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/></svg><svg class="sun" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M12 2.5v2.5M12 19v2.5M2.5 12H5M19 12h2.5M5.3 5.3l1.8 1.8M16.9 16.9l1.8 1.8M5.3 18.7l1.8-1.8M16.9 7.1l1.8-1.8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>`;

function readDocs() {
  return readdirSync(DOCS)
    .filter((f) => f.endsWith(".md"))
    .map((file) => {
      const { meta, body } = frontmatter(readFileSync(path.join(DOCS, file), "utf8"));
      const name = file.replace(/\.md$/, "");
      return { file, name, meta, body, path: name === "index" ? "/docs/" : `/docs/${name}/` };
    })
    .sort((a, b) => Number(a.meta.order ?? 99) - Number(b.meta.order ?? 99));
}

const NAV = [["Docs", "/docs/"], ["Install", "/docs/install/"], ["Privacy", "/docs/privacy/"], ["GitHub", GITHUB]];

function layout({ title, description, body, pagePath, assets }) {
  const full = pagePath === "/" ? "Runlight | Analytics that lives inside your app" : `${title} | Runlight`;
  const here = (href) => (!href.startsWith("http") && (href === pagePath || (href === "/docs/" && pagePath.startsWith("/docs/") && !NAV.some(([, h]) => h !== "/docs/" && h === pagePath))) ? ' aria-current="page"' : "");
  const links = NAV.map(([label, href]) => `<a href="${href}"${here(href)}>${label}</a>`).join("");
  const col = (head, items) => `<div><p class="foot-head">${head}</p><ul>${items.map(([l, h]) => `<li><a href="${h}"${h.startsWith("http") ? ' rel="noopener"' : ""}>${l}</a></li>`).join("")}</ul></div>`;
  return `<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(full)}</title>
<meta name="description" content="${escape(description)}">
<link rel="canonical" href="${SITE}${pagePath}">
<meta property="og:title" content="${escape(full)}">
<meta property="og:description" content="${escape(description)}">
<meta property="og:url" content="${SITE}${pagePath}">
<meta property="og:type" content="website">
<meta property="og:image" content="${SITE}/assets/shots/hero-dark.webp">
<meta name="twitter:card" content="summary_large_image">
<meta name="theme-color" content="#09090b">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<script src="${assets.theme}"></script>
<link rel="stylesheet" href="https://use.typekit.net/guv6qty.css">
<link rel="stylesheet" href="${assets.css}">
<script src="${assets.js}" defer></script>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<div class="page">
  <nav class="top" aria-label="Site">
    <div class="links">${links}</div>
    <details class="menu"><summary>Menu</summary><ol>${NAV.map(([l, h]) => `<li><a href="${h}">${l}</a></li>`).join("")}</ol></details>
    <a class="brand" href="/" title="Runlight">${MARK}<span translate="no">Runlight</span></a>
  </nav>
  <main id="main">
${body}
  </main>
  <footer>
    <div class="foot-top">
      <div class="foot-about"><a class="brand" href="/">${MARK}<span translate="no">Runlight</span></a><p>Web analytics that lives inside your app. Open source, no cookies, and nothing personal stored.</p></div>
      <nav class="foot-cols" aria-label="Footer">
        ${col("Docs", [["Getting started", "/docs/"], ["Install", "/docs/install/"], ["Tracking", "/docs/tracking/"], ["The dashboard", "/docs/dashboard/"], ["Scheduled check", "/docs/cron/"]])}
        ${col("Features", [["Goals", "/docs/goals/"], ["Short links", "/docs/links/"], ["AI sources", "/docs/ai/"], ["Email reports", "/docs/reports/"]])}
        ${col("Reference", [["Configuration", "/docs/configuration/"], ["HTTP API", "/docs/api/"], ["Privacy", "/docs/privacy/"], ["Prompt for agents", "/prompt.txt"], ["llms.txt", "/llms.txt"]])}
        ${col("Project", [["GitHub", GITHUB], ["npm", "https://www.npmjs.com/package/@runlight/sdk"], ["License", `${GITHUB}/blob/main/LICENSE`]])}
      </nav>
    </div>
    <div class="foot-end">
      <p>© ${new Date().getFullYear()} Runlight. MIT licensed. Made by <a href="https://joncphillips.com" rel="me noopener">Jon C. Phillips</a>.</p>
      <button class="theme" type="button" title="Light or dark (Shift+Cmd+D, or Shift+Ctrl+D)" aria-label="Switch between light and dark">${THEME_ICONS}</button>
    </div>
  </footer>
</div>
</body>
</html>
`;
}

function docPage(doc, docs, assets) {
  headingIds = new Set();
  pageToc.length = 0;
  const html = curly(marked.parse(doc.body));
  const groups = [];
  for (const d of docs) {
    const g = d.meta.group ?? "Docs";
    if (!groups.find((x) => x.name === g)) groups.push({ name: g, docs: [] });
    groups.find((x) => x.name === g).docs.push(d);
  }
  const num = (d) => String(docs.indexOf(d) + 1).padStart(2, "0");
  const list = groups
    .map((g) => `<p class="label">${escape(g.name)}</p><ol>${g.docs.map((d) => `<li><a href="${d.path}"${d === doc ? ' aria-current="page"' : ""}><span>${num(d)}</span><span>${escape(d.meta.nav ?? d.meta.title)}</span></a></li>`).join("")}</ol>`)
    .join("");
  const at = docs.indexOf(doc);
  const prev = docs[at - 1];
  const next = docs[at + 1];
  const pager = `<nav class="pager" aria-label="Pages">${prev ? `<a href="${prev.path}"><small>Previous</small>${escape(prev.meta.title)}</a>` : ""}${next ? `<a class="next" href="${next.path}"><small>Next</small>${escape(next.meta.title)}</a>` : ""}</nav>`;
  const toc = pageToc.length > 1 ? `<nav class="toc" aria-label="On this page"><p class="label">On this page</p><ul>${pageToc.map((h) => `<li><a href="#${h.id}">${h.text}</a></li>`).join("")}</ul></nav>` : "<span></span>";
  const body = `<div class="docs">
<aside class="docs-side" aria-label="Docs">${list}</aside>
<article class="doc">
<details class="docs-menu"><summary>All docs</summary>${list}</details>
<p class="label">${escape(doc.meta.group ?? "Docs")}</p>
<h1>${escape(doc.meta.title)}</h1>
${doc.meta.description ? `<p class="lede">${escape(doc.meta.description)}</p>` : ""}
${html}
${pager}
<p class="edit"><a href="${GITHUB}/blob/main/site/docs/${doc.file}" rel="noopener">Edit this page on GitHub</a></p>
</article>
${toc}
</div>`;
  return layout({ title: doc.meta.title, description: doc.meta.description ?? "", body, pagePath: doc.path, assets });
}

function build() {
  rmSync(DIST, { recursive: true, force: true });
  mkdirSync(path.join(DIST, "assets"), { recursive: true });
  cpSync(path.join(SRC, "assets"), path.join(DIST, "assets"), { recursive: true });

  const assets = {};
  for (const [key, file] of [["css", "style.css"], ["js", "site.js"], ["theme", "theme.js"]]) {
    const text = readFileSync(path.join(SRC, file), "utf8");
    const name = file.replace(/\.(\w+)$/, `.${digest(text)}.$1`);
    writeFileSync(path.join(DIST, "assets", name), text);
    assets[key] = `/assets/${name}`;
  }
  writeFileSync(path.join(DIST, "favicon.svg"), FAVICON);

  const landing = readFileSync(path.join(SRC, "landing.html"), "utf8");
  writeFileSync(
    path.join(DIST, "index.html"),
    layout({ title: "Runlight", description: "Open source web analytics that installs into your app like any other package. Your database, your domain, no cookies.", body: curly(landing), pagePath: "/", assets }),
  );

  const docs = readDocs();
  for (const doc of docs) {
    const dir = path.join(DIST, doc.path);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "index.html"), docPage(doc, docs, assets));
  }

  const prompt = readFileSync(path.join(SRC, "prompt.txt"), "utf8");
  writeFileSync(path.join(DIST, "prompt.txt"), prompt);
  writeFileSync(
    path.join(DIST, "llms.txt"),
    `# Runlight\n\n> Open source web analytics that lives inside your app: a package, a route, and a script tag. Docs below are plain Markdown.\n\n## Docs\n\n${docs.map((d) => `- [${d.meta.title}](${SITE}${d.path}index.md): ${d.meta.description ?? ""}`).join("\n")}\n\n## Setup prompt\n\n- [prompt.txt](${SITE}/prompt.txt): instructions a coding agent can follow to add Runlight to an app\n`,
  );
  // Each doc as Markdown too, for agents.
  for (const doc of docs) writeFileSync(path.join(DIST, doc.path, "index.md"), `# ${doc.meta.title}\n\n${doc.meta.description ? `${doc.meta.description}\n\n` : ""}${doc.body}`);

  writeFileSync(path.join(DIST, "robots.txt"), `User-agent: *\nAllow: /\nSitemap: ${SITE}/sitemap.xml\n`);
  writeFileSync(
    path.join(DIST, "sitemap.xml"),
    `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${["/", ...docs.map((d) => d.path)].map((p) => `  <url><loc>${SITE}${p}</loc></url>`).join("\n")}\n</urlset>\n`,
  );
  writeFileSync(
    path.join(DIST, "404.html"),
    layout({ title: "Not found", description: "", body: `<section class="notfound"><p class="label">404</p><h1>Nothing here.</h1><p>That page does not exist. Try <a href="/docs/">the docs</a> or <a href="/">the home page</a>.</p></section>`, pagePath: "/404/", assets }),
  );
  return docs;
}

/** Every internal link and anchor in the built site points at something real. */
function checkLinks() {
  const pages = new Map();
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".html")) pages.set(`/${path.relative(DIST, full)}`.replace(/index\.html$/, ""), readFileSync(full, "utf8"));
    }
  };
  walk(DIST);
  const broken = [];
  for (const [from, html] of pages) {
    for (const [, href] of html.matchAll(/href="([^"]+)"/g)) {
      if (/^(https?:|mailto:)/.test(href)) continue;
      const [target, anchor] = href.split("#");
      const page = target === "" ? from : target;
      const exists = page.startsWith("/assets/") || existsSync(path.join(DIST, page)) || pages.has(page);
      if (!exists) broken.push(`${from} -> ${href}`);
      else if (anchor && pages.has(page) && !pages.get(page).includes(`id="${anchor}"`)) broken.push(`${from} -> ${href} (no such heading)`);
    }
  }
  return broken;
}

const docs = build();
if (CHECK) {
  const broken = checkLinks();
  rmSync(DIST, { recursive: true, force: true });
  if (broken.length) {
    console.error(`site: ${broken.length} broken links\n  ${broken.join("\n  ")}`);
    process.exit(1);
  }
  console.log(`site: ${docs.length} docs, every link resolves`);
} else {
  console.log(`site: built ${docs.length} docs into dist/`);
}

if (SERVE) {
  for (const dir of [SRC, DOCS]) watch(dir, { recursive: true }, () => {
    try {
      build();
    } catch (error) {
      console.error(error.message);
    }
  });
  const types = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".svg": "image/svg+xml", ".webp": "image/webp", ".txt": "text/plain; charset=utf-8", ".xml": "application/xml", ".md": "text/markdown; charset=utf-8", ".png": "image/png" };
  createServer((req, res) => {
    let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (p.endsWith("/")) p += "index.html";
    const file = path.join(DIST, p);
    if (!file.startsWith(DIST) || !existsSync(file)) {
      res.writeHead(404, { "content-type": types[".html"] });
      return res.end(readFileSync(path.join(DIST, "404.html")));
    }
    res.writeHead(200, { "content-type": types[path.extname(file)] ?? "application/octet-stream" });
    res.end(readFileSync(file));
  }).listen(PORT, () => console.log(`site: http://localhost:${PORT}`));
}
