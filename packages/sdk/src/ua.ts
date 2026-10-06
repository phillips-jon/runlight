import { AI_AGENTS, BOT_PATTERN, type AiAgent } from "./data/agents.js";

export interface Client {
  browser: string;
  browserVersion: string;
  os: string;
  osVersion: string;
  device: "desktop" | "mobile" | "tablet";
}

/** Low entropy client hints, sent by Chromium browsers on every request. */
export interface ClientHints {
  brands?: string | null;
  mobile?: string | null;
  platform?: string | null;
}

export function aiAgent(ua: string): AiAgent | null {
  const lower = ua.toLowerCase();
  return AI_AGENTS.find((agent) => lower.includes(agent.token)) ?? null;
}

export function isBot(ua: string): boolean {
  if (ua.length < 20 || !/mozilla|opera/i.test(ua)) return true;
  return BOT_PATTERN.test(ua);
}

const BROWSERS: Array<[name: string, pattern: RegExp]> = [
  ["Edge", /(?:Edg|EdgA|EdgiOS|Edge)\/(\d+)/],
  ["Opera", /(?:OPR|OPiOS|Opera)\/(\d+)/],
  ["Samsung Internet", /SamsungBrowser\/(\d+)/],
  ["Yandex Browser", /YaBrowser\/(\d+)/],
  ["Vivaldi", /Vivaldi\/(\d+)/],
  ["UC Browser", /UCBrowser\/(\d+)/],
  ["DuckDuckGo", /(?:Ddg|DuckDuckGo)\/(\d+)/],
  ["Facebook", /FB(?:AV|_IAB)\/(\d+)/],
  ["Instagram", /Instagram (\d+)/],
  ["Firefox", /(?:Firefox|FxiOS)\/(\d+)/],
  ["Chrome", /(?:CriOS|Chrome)\/(\d+)/],
  ["Safari", /Version\/(\d+)[\d.]* (?:Mobile\/\S+ )?Safari\//],
  ["Internet Explorer", /(?:MSIE |Trident\/.*rv:)(\d+)/],
];

const WINDOWS: Record<string, string> = {
  "10.0": "10",
  "6.3": "8.1",
  "6.2": "8",
  "6.1": "7",
  "6.0": "Vista",
  "5.1": "XP",
};

function unquote(value: string | null | undefined): string {
  return (value ?? "").replace(/"/g, "").trim();
}

export function parseClient(ua: string, hints: ClientHints = {}, screenWidth?: number): Client {
  let browser = "Other";
  let browserVersion = "";
  for (const [name, pattern] of BROWSERS) {
    const match = pattern.exec(ua);
    if (match) {
      browser = name;
      browserVersion = match[1] ?? "";
      break;
    }
  }
  if (browser === "Chrome" && /; wv\)/.test(ua)) browser = "Android WebView";
  // Brave looks like Chrome in the user agent but names itself in the hints.
  if (browser === "Chrome" && /"Brave"/.test(hints.brands ?? "")) browser = "Brave";

  let os = "Other";
  let osVersion = "";
  let match: RegExpExecArray | null;
  if ((match = /Windows NT (\d+\.\d+)/.exec(ua))) {
    os = "Windows";
    osVersion = WINDOWS[match[1] ?? ""] ?? "";
  } else if ((match = /(?:iPhone|iPad|iPod).*? OS (\d+)/.exec(ua))) {
    os = "iOS";
    osVersion = match[1] ?? "";
  } else if ((match = /Android (\d+)/.exec(ua))) {
    os = "Android";
    osVersion = match[1] ?? "";
  } else if (/Android/.test(ua)) {
    os = "Android";
  } else if (/CrOS/.test(ua)) {
    os = "Chrome OS";
  } else if (/Mac OS X|Macintosh/.test(ua)) {
    // macOS froze its version in the user agent at 10.15, so it says nothing.
    os = "macOS";
  } else if (/Linux|X11/.test(ua)) {
    os = "Linux";
  }
  const platform = unquote(hints.platform);
  if (os === "Other" && platform) os = platform === "macOS" ? "macOS" : platform;

  let device: Client["device"] = "desktop";
  if (/iPad|Tablet|PlayBook|Silk/.test(ua) || (os === "Android" && !/Mobile/.test(ua))) {
    device = "tablet";
  } else if (/Mobi|iPhone|iPod|Opera Mini|IEMobile/.test(ua) || unquote(hints.mobile) === "?1") {
    device = "mobile";
  } else if (os === "macOS" && screenWidth !== undefined && [768, 810, 820, 834, 1024].includes(screenWidth)) {
    // iPadOS asks for desktop sites with a Mac user agent; the screen gives it away.
    device = "tablet";
    os = "iOS";
  }

  return { browser, browserVersion, os, osVersion, device };
}
