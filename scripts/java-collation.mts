/**
 * Writes pairs of strings with Node's Math.sign(a.localeCompare(b))
 * (packages/java/runlight/src/test/resources/sh/runlight/collation.json), for AssistantTest to check the Java
 * port's localeCompare against: the order Assistant.listModels sorts model names in. The strings are drawn, with a
 * fixed seed, from ASCII, its spaces and controls, U+0085, U+00A0, and Latin letters with marks, precomposed and
 * not, as the Go port's collation test draws them; model names like the ones services list are added. With --check
 * it writes nothing and only says whether the file is current.
 *
 * Run from the repo root with Node 24: node --import tsx scripts/java-collation.mts [--check]
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const MARKS = [0x301, 0x300, 0x306, 0x302, 0x30c, 0x30a, 0x308, 0x30b, 0x303, 0x307, 0x327, 0x328, 0x304, 0x309, 0x30f, 0x311, 0x31b, 0x323, 0x324, 0x325, 0x326, 0x32d, 0x32e, 0x330, 0x331].map((c) => String.fromCodePoint(c));

/** Latin letters whose canonical decomposition is an ASCII letter and marks. */
const latin: string[] = [];
for (const [from, to] of [
  [0xc0, 0x24f],
  [0x1e00, 0x1eff],
]) {
  for (let c = from!; c <= to!; c++) {
    const letter = String.fromCodePoint(c);
    const parts = [...letter.normalize("NFD")];
    if (parts.length > 1 && /^[A-Za-z]$/.test(parts[0]!) && parts.slice(1).every((m) => MARKS.includes(m))) latin.push(letter);
  }
}

const ascii: string[] = [];
for (let c = 0x20; c < 0x7f; c++) ascii.push(String.fromCharCode(c));
const spaces = ["\t", "\n", "\v", "\f", "\r", "\u0001", "\u0085", " "];

/** mulberry32, so the pairs are the same on every run. */
let seed = 0x52554e4c;
function random(): number {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = <T,>(list: T[]): T => list[Math.floor(random() * list.length)]!;

function piece(): string {
  const roll = random();
  if (roll < 0.45) return pick(ascii);
  if (roll < 0.55) return pick(spaces);
  if (roll < 0.8) return pick(latin);
  if (roll < 0.9) return pick(latin).normalize("NFD");
  return pick(MARKS);
}

function text(): string {
  let out = "";
  const length = Math.floor(random() * 6);
  for (let i = 0; i < length; i++) out += piece();
  return out;
}

const pairs: [string, string, number][] = [];
const add = (a: string, b: string) => pairs.push([a, b, Math.sign(a.localeCompare(b))]);
for (let i = 0; i < 4000; i++) {
  const a = text();
  const roll = random();
  // Half the pairs share a beginning, so the later levels and later characters decide them.
  if (roll < 0.5) {
    const cut = Math.floor(random() * (a.length + 1));
    add(a, a.slice(0, cut) + text());
  } else if (roll < 0.6) {
    add(a, a.normalize(random() < 0.5 ? "NFD" : "NFC"));
  } else if (roll < 0.7) {
    add(a, random() < 0.5 ? a.toUpperCase() : a.toLowerCase());
  } else {
    add(a, text());
  }
}

const models = ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "GPT-4o", "o1", "o3-mini", "claude-3-5-sonnet-latest", "claude-3-5-haiku", "claude-sonnet-4-5", "llama3.1:8b", "llama3.1:70b", "llama3.2", "Llama-3.3-70B", "mistral-large", "mistral_large", "mistral.large", "qwen2.5:7b", "qwen2.5-coder:7b", "deepseek-r1:1.5b", "deepseek-r1", "gemma2:2b", "gemma-2-9b-it", "phi3", "phi-3", "phi_3", "models/gemini-1.5-pro", "models/gemini-1.5-flash", "text-embedding-3-small", "a", "A", "b", "B", "10", "9", "1.5", "1-5", "1_5", "1 5"];
for (const a of models) for (const b of models) if (a !== b) add(a, b);

const file = fileURLToPath(new URL("../packages/java/runlight/src/test/resources/sh/runlight/collation.json", import.meta.url));
const out = `[\n${pairs.map((p) => JSON.stringify(p)).join(",\n")}\n]\n`;
if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(file, "utf8");
  } catch {
    // Missing counts as stale.
  }
  if (current !== out) {
    console.error(`${file} is stale: run node --import tsx scripts/java-collation.mts`);
    process.exit(1);
  }
  console.log("collation.json is current");
} else {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, out);
  console.log(`wrote ${pairs.length} pairs to ${file}`);
}
