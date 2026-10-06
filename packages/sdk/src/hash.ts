const encoder = new TextEncoder();

function hex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
}

/**
 * The day's visitor hash: SHA-256 of salt, site, IP, and user agent, cut to
 * 64 bits. The salt changes every day and old salts are deleted, so the hash
 * cannot be recomputed and does not follow anyone across days.
 */
export async function visitorHash(salt: string, site: string, ip: string, ua: string): Promise<string> {
  return (await sha256(`${salt}\n${site}\n${ip}\n${ua}`)).slice(0, 16);
}

export function randomId(bytes = 12): string {
  const values = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(values, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function randomSalt(): string {
  return randomId(32);
}
