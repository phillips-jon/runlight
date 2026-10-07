import { ENGLISH, LOCALES } from "./generated/dashboard.js";

/**
 * The dashboard's translations, for text the server writes (email reports).
 * Same keys, same placeholders, so every language stays in one place.
 */
const parsed = new Map<string, Record<string, string>>();

function table(lang: string): Record<string, string> {
  let found = parsed.get(lang);
  if (!found) {
    const raw = lang === "en" ? ENGLISH : LOCALES[lang];
    found = raw ? (JSON.parse(raw) as Record<string, string>) : {};
    parsed.set(lang, found);
  }
  return found;
}

export const languages = (): string[] => ["en", ...Object.keys(LOCALES)];

export function translator(lang: string) {
  const code = languages().includes(lang) ? lang : "en";
  const fill = (text: string, vars: Record<string, string | number>) => text.replace(/\{(\w+)\}/g, (m, k: string) => (k in vars ? String(vars[k]) : m));
  const t = (key: string, vars: Record<string, string | number> = {}) => fill(table(code)[key] ?? table("en")[key] ?? key, vars);
  const rules = new Intl.PluralRules(code);
  const tn = (key: string, n: number, vars: Record<string, string | number> = {}) => {
    const form = rules.select(n);
    const own = table(code)[`${key}_${form}`] ?? table(code)[`${key}_other`];
    return own ? fill(own, vars) : t(`${key}_other`, vars);
  };
  return { t, tn, lang: code };
}
