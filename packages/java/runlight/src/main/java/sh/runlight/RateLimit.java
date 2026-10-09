package sh.runlight;

import java.util.HashMap;
import java.util.HexFormat;
import java.util.Map;
import java.util.function.LongSupplier;

/**
 * Counts tracker requests per address in fixed one-minute windows, in memory. Addresses are hashed
 * with a key made at start, so the map never holds an IP, and the whole map is dropped at the end
 * of each window. Safe to share between threads. Several servers behind a load balancer each count
 * on their own, as the TypeScript SDK's processes do.
 */
public final class RateLimit {
  private final long perMinute;
  private final LongSupplier now;
  private final byte[] key = Hash.randomBytes(16);
  private long window = 0;
  private final Map<String, Long> counts = new HashMap<>();

  /**
   * @param perMinute requests each address may make in a minute
   * @param now the clock, in milliseconds
   */
  public RateLimit(long perMinute, LongSupplier now) {
    this.perMinute = perMinute;
    this.now = now;
  }

  /** True while this address is under its limit for the current minute. */
  public synchronized boolean allow(String ip) {
    // No address (a bare adapter with no context) cannot be told apart, so it is not limited.
    if (ip == null || ip.isEmpty()) {
      return true;
    }
    long current = Math.floorDiv(now.getAsLong(), 60_000L);
    if (current != window) {
      window = current;
      counts.clear();
    }
    String id = hash(ip);
    long count = counts.getOrDefault(id, 0L) + 1;
    counts.put(id, count);
    return count <= perMinute;
  }

  private String hash(String ip) {
    byte[] text = Js.utf8(ip);
    byte[] bytes = new byte[key.length + text.length];
    System.arraycopy(key, 0, bytes, 0, key.length);
    System.arraycopy(text, 0, bytes, key.length, text.length);
    byte[] digest = Hash.sha256Bytes(bytes);
    return HexFormat.of().formatHex(digest, 0, 8);
  }
}
