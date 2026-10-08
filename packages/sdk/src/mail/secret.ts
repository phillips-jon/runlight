/**
 * Keys kept in the database (the mail service's, the AI Assistant's, and the tokens for connected
 * installs) are encrypted with AES-GCM, under a key derived from a secret only the server has:
 * `RUNLIGHT_SECRET`, or else the dashboard token. A copied database alone does not give them away.
 * The label says "mail" because mail came first; changing it would make every saved key unreadable.
 */
const encoder = new TextEncoder();

async function keyFor(secret: string): Promise<CryptoKey> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(`runlight-mail:${secret}`));
  return crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
}

const toBase64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const fromBase64 = (text: string) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

/** `v1:<iv>:<ciphertext>`, or `plain:<json>` when the server has no secret to encrypt with. */
export async function seal(value: string, secret: string | null): Promise<string> {
  if (!secret) return `plain:${value}`;
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await keyFor(secret), encoder.encode(value)));
  return `v1:${toBase64(iv)}:${toBase64(data)}`;
}

/** The sealed value, or null when it cannot be opened (a different secret, or damaged). */
export async function unseal(sealed: string, secret: string | null): Promise<string | null> {
  if (sealed.startsWith("plain:")) return sealed.slice(6);
  const [version, iv, data] = sealed.split(":");
  if (version !== "v1" || !iv || !data || !secret) return null;
  try {
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromBase64(iv) }, await keyFor(secret), fromBase64(data));
    return new TextDecoder().decode(plain);
  } catch {
    return null;
  }
}
