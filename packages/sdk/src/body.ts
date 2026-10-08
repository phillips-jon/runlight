/** A body longer than the reader allows. */
export class BodyTooLong extends Error {}

/**
 * Reads a response body as text, up to maxBytes. Past that it stops reading,
 * cancels the rest, and throws BodyTooLong, so an install or a page that
 * answers without end never fills memory.
 */
export async function readTextCapped(response: Response, maxBytes: number): Promise<string> {
  if (!response.body) return "";
  const declared = Number(response.headers.get("content-length"));
  if (declared > maxBytes) {
    await response.body.cancel().catch(() => {});
    throw new BodyTooLong(`Body over ${maxBytes} bytes`);
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel().catch(() => {});
      throw new BodyTooLong(`Body over ${maxBytes} bytes`);
    }
    chunks.push(value);
  }
  const whole = new Uint8Array(size);
  let at = 0;
  for (const chunk of chunks) {
    whole.set(chunk, at);
    at += chunk.byteLength;
  }
  return new TextDecoder().decode(whole);
}

/** Reads a response body as JSON, up to maxBytes, as readTextCapped does. */
export async function readJsonCapped<T = unknown>(response: Response, maxBytes: number): Promise<T> {
  return JSON.parse(await readTextCapped(response, maxBytes)) as T;
}
