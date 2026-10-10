/**
 * Light, dark, or the system's choice, remembered per browser and shared by
 * every control that changes it. Light until someone picks otherwise, or
 * inside a CMS, the admin's own.
 */
export type ThemeChoice = "system" | "light" | "dark";

const KEY = "runlight_theme";
const listeners = new Set<() => void>();

/**
 * Light, except inside a CMS, where the frame's ?theme= says whether the admin around it is light or dark, and
 * the device's setting stands in when it does not say.
 */
function fallback(): ThemeChoice {
  if (document.getElementById("app")?.dataset.embedOrigin === undefined) return "light";
  const asked = new URLSearchParams(location.search).get("theme");
  return asked === "light" || asked === "dark" ? asked : "system";
}

export function themeChoice(): ThemeChoice {
  try {
    const stored = localStorage.getItem(KEY);
    if (stored === "light" || stored === "dark" || stored === "system") return stored;
  } catch {}
  return fallback();
}

export function isDark(): boolean {
  const choice = themeChoice();
  return choice === "system" ? matchMedia("(prefers-color-scheme: dark)").matches : choice === "dark";
}

export function applyTheme(): void {
  const choice = themeChoice();
  if (choice === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = choice;
}

export function setTheme(choice: ThemeChoice): void {
  try {
    localStorage.setItem(KEY, choice);
  } catch {}
  applyTheme();
  for (const listener of listeners) listener();
}

export function onThemeChange(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
