package sh.runlight;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A reader for MaxMind DB files (the MMDB format that MaxMind's GeoLite2 and DB-IP's free databases
 * use), in plain Java so location needs no library. It answers what the TypeScript server's
 * mmdb-lib answers: the record for an address, maps with string keys, or null when the address is
 * not in the database. A uint64 or uint128 past 2^53 is its decimal text.
 *
 * <p>A database opened from a file is mapped into memory, so the operating system reads the pages a
 * lookup needs as it needs them.
 *
 * <p>Format: https://maxmind.github.io/MaxMind-DB/
 */
public final class Mmdb {
  private static final byte[] METADATA_MARKER = {
    (byte) 0xAB, (byte) 0xCD, (byte) 0xEF, 'M', 'a', 'x', 'M', 'i', 'n', 'd', '.', 'c', 'o', 'm'
  };

  /** The metadata sits in the file's last 128 KiB. */
  private static final int METADATA_MAX = 131072;

  private final ByteBuffer bytes;
  private final Map<String, Object> metadata;
  private final long nodeCount;
  private final int recordSize;
  private final int nodeBytes;
  private final long dataStart;
  private long ipv4Start = -1;

  /** A database held in memory. */
  public Mmdb(byte[] database) {
    this(ByteBuffer.wrap(database));
  }

  private Mmdb(ByteBuffer bytes) {
    this.bytes = bytes;
    int size = bytes.limit();
    int tailStart = Math.max(0, size - METADATA_MAX);
    int at = -1;
    for (int i = size - METADATA_MARKER.length; i >= tailStart; i--) {
      boolean match = true;
      for (int k = 0; k < METADATA_MARKER.length; k++) {
        if (bytes.get(i + k) != METADATA_MARKER[k]) {
          match = false;
          break;
        }
      }
      if (match) {
        at = i;
        break;
      }
    }
    if (at < 0) {
      throw new IllegalArgumentException("Not a MaxMind DB file: no metadata");
    }
    int start = at + METADATA_MARKER.length;
    Object decoded = decode(start, start)[0];
    if (!(decoded instanceof Map<?, ?>)
        || !Js.map(decoded).containsKey("node_count")
        || !Js.map(decoded).containsKey("record_size")
        || !Js.map(decoded).containsKey("ip_version")) {
      throw new IllegalArgumentException("Not a MaxMind DB file: bad metadata");
    }
    metadata = Js.map(decoded);
    nodeCount = Js.asLong(metadata.get("node_count"));
    recordSize = (int) Js.asLong(metadata.get("record_size"));
    if (recordSize != 24 && recordSize != 28 && recordSize != 32) {
      throw new IllegalArgumentException("Unsupported record size " + recordSize);
    }
    nodeBytes = recordSize / 4;
    dataStart = nodeCount * nodeBytes + 16;
  }

  /** A database read from its file as lookups need it. */
  public static Mmdb open(Path file) {
    try (FileChannel channel = FileChannel.open(file, StandardOpenOption.READ)) {
      return new Mmdb(channel.map(FileChannel.MapMode.READ_ONLY, 0, channel.size()));
    } catch (IOException e) {
      throw new UncheckedIOException("Could not read " + file, e);
    }
  }

  /** The database's metadata. */
  public Map<String, Object> metadata() {
    return metadata;
  }

  private int byteAt(long at) {
    if (at < 0 || at >= bytes.limit()) {
      throw new IllegalStateException("Invalid MaxMind DB: read past the end");
    }
    return bytes.get((int) at) & 0xFF;
  }

  private byte[] read(long at, int length) {
    if (at < 0 || at + length > bytes.limit()) {
      throw new IllegalStateException("Invalid MaxMind DB: read past the end");
    }
    byte[] out = new byte[length];
    bytes.get((int) at, out);
    return out;
  }

  /**
   * The record for an address, or null. Throws {@link IllegalArgumentException} for text that is
   * not an IP address.
   */
  public Object get(String ip) {
    byte[] packed = Ip.parse(ip);
    if (packed == null) {
      throw new IllegalArgumentException("Not an IP address: " + ip);
    }
    boolean v6 = packed.length == 16;
    long version = Js.asLong(metadata.get("ip_version"));
    if (v6 && version == 4) {
      throw new IllegalArgumentException(
          "An IPv6 address cannot be looked up in an IPv4-only database: " + ip);
    }
    long node = v6 || version == 4 ? 0 : ipv4Start();
    int bits = packed.length * 8;
    for (int i = 0; i < bits && node < nodeCount; i++) {
      int bit = ((packed[i >> 3] & 0xFF) >> (7 - (i & 7))) & 1;
      node = record(node, bit);
    }
    // The node count itself means no record, and so does a tree that ends before the address does.
    if (node <= nodeCount) {
      return null;
    }
    return decode(dataStart + node - nodeCount - 16, dataStart)[0];
  }

  /** IPv4 addresses live under ::/96 in an IPv6 tree: the node 96 left turns down. */
  private synchronized long ipv4Start() {
    if (ipv4Start < 0) {
      long node = 0;
      for (int i = 0; i < 96 && node < nodeCount; i++) {
        node = record(node, 0);
      }
      ipv4Start = node;
    }
    return ipv4Start;
  }

  private long record(long node, int right) {
    byte[] b = read(node * nodeBytes, nodeBytes);
    switch (recordSize) {
      case 24 -> {
        int at = right * 3;
        return ((long) (b[at] & 0xFF) << 16) | ((b[at + 1] & 0xFF) << 8) | (b[at + 2] & 0xFF);
      }
      case 28 -> {
        if (right == 0) {
          return ((long) (b[3] & 0xF0) << 20)
              | ((b[0] & 0xFF) << 16)
              | ((b[1] & 0xFF) << 8)
              | (b[2] & 0xFF);
        }
        return ((long) (b[3] & 0x0F) << 24)
            | ((b[4] & 0xFF) << 16)
            | ((b[5] & 0xFF) << 8)
            | (b[6] & 0xFF);
      }
      default -> {
        int at = right * 4;
        return ((long) (b[at] & 0xFF) << 24)
            | ((b[at + 1] & 0xFF) << 16)
            | ((b[at + 2] & 0xFF) << 8)
            | (b[at + 3] & 0xFF);
      }
    }
  }

  /** Decodes the value at {@code at}; pointers are offsets from {@code base}. */
  private Object[] decode(long at, long base) {
    int control = byteAt(at++);
    int type = control >> 5;
    if (type == 1) {
      // A pointer: up to four more bytes of offset, then the value found there.
      int ss = (control >> 3) & 3;
      long vvv = control & 7;
      long pointer =
          switch (ss) {
            case 0 -> (vvv << 8) | byteAt(at);
            case 1 -> ((vvv << 16) | (byteAt(at) << 8) | byteAt(at + 1)) + 2048;
            case 2 ->
                ((vvv << 24) | ((long) byteAt(at) << 16) | (byteAt(at + 1) << 8) | byteAt(at + 2))
                    + 526336;
            default -> unsigned(read(at, 4));
          };
      Object value = decode(base + pointer, base)[0];
      return new Object[] {value, at + ss + 1};
    }
    if (type == 0) {
      type = 7 + byteAt(at++);
    }
    int size = control & 0x1F;
    if (size >= 29) {
      int extra = size - 28;
      int n = 0;
      for (int i = 0; i < extra; i++) {
        n = (n << 8) | byteAt(at + i);
      }
      size = (size == 29 ? 29 : size == 30 ? 285 : 65821) + n;
      at += extra;
    }
    switch (type) {
      case 2 -> {
        return new Object[] {new String(read(at, size), StandardCharsets.UTF_8), at + size};
      }
      case 3 -> {
        return new Object[] {Js.num(ByteBuffer.wrap(read(at, 8)).getDouble()), at + 8};
      }
      case 4 -> {
        return new Object[] {read(at, size), at + size};
      }
      case 5, 6 -> {
        return new Object[] {unsigned(read(at, size)), at + size};
      }
      case 7 -> {
        Map<String, Object> map = new LinkedHashMap<>();
        for (int i = 0; i < size; i++) {
          Object[] key = decode(at, base);
          Object[] value = decode((long) key[1], base);
          map.put(String.valueOf(key[0]), value[0]);
          at = (long) value[1];
        }
        return new Object[] {map, at};
      }
      case 8 -> {
        long n = unsigned(read(at, size));
        if (size == 4 && n >= 0x80000000L) {
          n -= 0x100000000L;
        }
        return new Object[] {n, at + size};
      }
      case 9, 10 -> {
        BigInteger n = new BigInteger(1, read(at, size));
        Object value = n.bitLength() <= 53 ? (Object) n.longValue() : n.toString();
        return new Object[] {value, at + size};
      }
      case 11 -> {
        List<Object> list = new ArrayList<>();
        for (int i = 0; i < size; i++) {
          Object[] item = decode(at, base);
          list.add(item[0]);
          at = (long) item[1];
        }
        return new Object[] {list, at};
      }
      case 14 -> {
        return new Object[] {size != 0, at};
      }
      case 15 -> {
        return new Object[] {Js.num((double) ByteBuffer.wrap(read(at, 4)).getFloat()), at + 4};
      }
      default -> throw new IllegalStateException("Invalid MaxMind DB: unknown data type " + type);
    }
  }

  private static long unsigned(byte[] bytes) {
    long n = 0;
    for (byte b : bytes) {
      n = (n << 8) | (b & 0xFF);
    }
    return n;
  }
}
