/**
 * Light, dark, or the system's choice, remembered per browser and shared by
 * every control that changes it. Light until someone picks otherwise.
 */
export type ThemeChoice = "system" | "light" | "dark";

const KEY = "runlight_theme";
const listeners = new Set<() => void>();

export function themeChoice(): ThemeChoice {
  try {
    const stored = localStorage.getItem(KEY);
    if (stored === "light" || stored === "dark" || stored === "system") return stored;
  } catch {}
  return "light";
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
