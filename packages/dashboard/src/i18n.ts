import type { ComponentChildren } from "preact";
import en from "./locales/en.json";

export type Messages = typeof en;
export type Key = keyof Messages;

/** Languages the dashboard speaks, by their own names. */
export const LANGUAGES: Array<[code: string, name: string]> = [
  ["en", "English"],
  ["fr", "Français"],
  ["es", "Español"],
  ["de", "Deutsch"],
  ["pt", "Português"],
];

const STORAGE = "runlight_language";
const urls: Record<string, string> = (() => {
  try {
    return JSON.parse(document.getElementById("app")?.dataset.locales ?? "{}") as Record<string, string>;
  } catch {
    return {};
  }
})();

let locale = "en";
let messages: Messages = en;
let plurals = new Intl.PluralRules("en");

export function currentLocale(): string {
  return locale;
}

/** The language to start in: the one picked before, else the browser's, else English. */
export function initialLocale(): string {
  let stored: string | null = null;
  try {
    stored = localStorage.getItem(STORAGE);
  } catch {}
  const wanted = [stored, ...(navigator.languages ?? [navigator.language])].filter(Boolean) as string[];
  for (const tag of wanted) {
    const code = tag.toLowerCase().split("-")[0]!;
    if (LANGUAGES.some(([c]) => c === code)) return code;
  }
  return "en";
}

/** Loads a language (only English is in the bundle) and makes it current. */
export async function setLocale(code: string, remember = false): Promise<void> {
  if (code === "en") {
    messages = en;
  } else {
    const url = urls[code];
    if (!url) throw new Error(`No messages for ${code}`);
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Could not load ${code}`);
    messages = { ...en, ...((await response.json()) as Partial<Messages>) };
  }
  locale = code;
  plurals = new Intl.PluralRules(code);
  document.documentElement.lang = code;
  if (remember) {
    try {
      localStorage.setItem(STORAGE, code);
    } catch {}
  }
}

function fill(text: string, vars: Record<string, string | number>): string {
  return text.replace(/\{(\w+)\}/g, (whole, name: string) => (name in vars ? String(vars[name]) : whole));
}

/** A message, with {name} placeholders filled. */
export function t(key: Key, vars: Record<string, string | number> = {}): string {
  return fill(messages[key] ?? en[key] ?? key, vars);
}

/**
 * A counted message: `key_one`, `key_other` (and any other plural forms the
 * language has), chosen by Intl.PluralRules, with {n} filled.
 */
export function tn(key: string, n: number, vars: Record<string, string | number> = {}): string {
  const form = plurals.select(n);
  const table = messages as unknown as Record<string, string>;
  const text = table[`${key}_${form}`] ?? table[`${key}_other`] ?? (en as unknown as Record<string, string>)[`${key}_other`] ?? key;
  return fill(text, { n, ...vars });
}

/** A message whose placeholders are elements, for sentences with bold or coloured parts. */
export function rich(key: Key, parts: Record<string, ComponentChildren>): ComponentChildren[] {
  const text = messages[key] ?? en[key] ?? key;
  const out: ComponentChildren[] = [];
  let last = 0;
  for (const match of text.matchAll(/\{(\w+)\}/g)) {
    out.push(text.slice(last, match.index));
    out.push(parts[match[1]!] ?? match[0]);
    last = (match.index ?? 0) + match[0].length;
  }
  out.push(text.slice(last));
  return out;
}
