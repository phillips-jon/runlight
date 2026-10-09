// Writes conformance/url.json: how JavaScript's URL, URLSearchParams, and
// number formatting answer a set of inputs, so another implementation can
// parse paths, queries, and hosts the same way and print numbers alike.
import { writeFileSync } from "node:fs";

const urls = [
  "https://example.com",
  "https://Example.COM/Pricing?x=1#top",
  "https://example.com:443/a",
  "http://example.com:8080/a/../b/./c",
  "https://example.com/café",
  "https://example.com/a b/c\"d<e>`f{g}",
  "https://example.com/%7Euser/%C3%A9",
  "https://example.com\\a\\b",
  "https://example.com/?q=a b&r='x'&s=ü",
  "https://example.com/#frag menté",
  "https://user:pa ss@example.com/",
  "https://0x7f.1/",
  "https://2130706433/",
  "https://[::1]:3000/x",
  "https://exa%41mple.com/",
  "https://bücher.example/",
  "https://example.com/a/%2e%2E/b",
  "https://example.com/a/b/..",
  "https://example.com/a/b/.",
  "https://example.com//double//slash",
  "https://example.com/emoji/\u{1F600}",
  "https://example.com/tab\there",
  "  https://example.com/trim  ",
  "HTTPS://EXAMPLE.COM/UPPER",
  "mailto:someone@example.com",
  "javascript:alert(1)",
  "https://example.com:99999/",
  "https://exa mple.com/",
  "not a url",
  "",
  "//example.com/x",
  "/relative",
];
const relative = [
  ["/pricing?x=1", "https://example.com/a/b"],
  ["pricing", "https://example.com/a/b"],
  ["../up", "https://example.com/a/b/c"],
  ["?only=query", "https://example.com/a/b"],
  ["#hash", "https://example.com/a?q=1"],
  ["//other.example/x", "https://example.com/a"],
  ["\\back\\slash", "https://example.com/a"],
  ["", "https://example.com/a?q#h"],
];

const parse = (input: string, base?: string) => {
  try {
    const u = new URL(input, base);
    return { href: u.href, protocol: u.protocol, username: u.username, password: u.password, hostname: u.hostname, port: u.port, host: u.host, origin: u.origin, pathname: u.pathname, search: u.search, hash: u.hash };
  } catch {
    return null;
  }
};

const queries = ["a=1&b=2", "?a=1&a=2&b", "q=a+b%20c", "x=%C3%A9&y=%E2%82%AC", "a[]=1&a.b=2", "=v&k=", "&&a=1&&", "bad=%ZZ&ok=1", "plus=1%2B1"];
const parsedQueries = queries.map((q) => {
  const p = new URLSearchParams(q);
  return { input: q, pairs: [...p], string: p.toString() };
});
const written = [
  { a: "b c", "é": "€", "x*y": "-._~!'()" },
  { path: "/a/b?c=d&e", empty: "" },
].map((pairs) => ({ pairs: Object.entries(pairs), string: new URLSearchParams(pairs).toString() }));

const numbers = [0, -0, 1, -1, 0.5, 1 / 3, 2 / 3, 1e-6, 1e-7, 1.5e-9, 123456789.123, 1e20, 1e21, 1.2e25, -4.5e-8, 0.1 + 0.2, 100, 99.99, 12.5, Number.MAX_SAFE_INTEGER];

const file = new URL("../conformance/url.json", import.meta.url);
writeFileSync(
  file,
  `${JSON.stringify(
    {
      description:
        "How JavaScript reads URLs and query strings and prints numbers. urls: new URL(input, base) and its parts, or null when it throws. queries: new URLSearchParams(input) as name and value pairs, and toString(). written: new URLSearchParams(pairs).toString(). numbers: String(n) for each n, which JSON.stringify also uses.",
      urls: urls.map((input) => ({ input, expect: parse(input) })),
      relative: relative.map(([input, base]) => ({ input, base, expect: parse(input!, base) })),
      queries: parsedQueries,
      written,
      numbers: numbers.map((n) => ({ n, text: String(n) })),
    },
    null,
    2,
  )}\n`,
);
console.log("conformance/url.json written");
