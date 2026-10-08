/**
 * Counts tracker requests per address in fixed one-minute windows, in memory.
 * Addresses are hashed with a key made at start, so the map never holds an IP,
 * and the whole map is dropped at the end of each window.
 */
export class RateLimit {
  private window = 0;
  private counts = new Map<string, number>();
  private readonly key = crypto.getRandomValues(new Uint8Array(16));

  constructor(
    private readonly perMinute: number,
    private readonly now: () => number,
  ) {}

  /** True while this address is under its limit for the current minute. */
  async allow(ip: string): Promise<boolean> {
    // No address (a bare adapter with no context) cannot be told apart, so it is not limited.
    if (!ip) return true;
    const window = Math.floor(this.now() / 60_000);
    if (window !== this.window) {
      this.window = window;
      this.counts.clear();
    }
    const id = await this.hash(ip);
    const count = (this.counts.get(id) ?? 0) + 1;
    this.counts.set(id, count);
    return count <= this.perMinute;
  }

  private async hash(ip: string): Promise<string> {
    const bytes = new Uint8Array(this.key.length + ip.length * 3);
    bytes.set(this.key);
    const { written } = new TextEncoder().encodeInto(ip, bytes.subarray(this.key.length));
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes.subarray(0, this.key.length + written)));
    let out = "";
    for (let i = 0; i < 8; i++) out += digest[i]!.toString(16).padStart(2, "0");
    return out;
  }
}
