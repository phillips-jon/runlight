package sh.runlight.accounts;

/**
 * scrypt (RFC 7914) in plain Java, since javax.crypto has none. It gives the same bytes as Node's
 * crypto.scrypt, so a password hashed by either implementation checks out in the other.
 */
public final class Scrypt {
  private Scrypt() {}

  /**
   * The derived key for a password and salt.
   *
   * @throws IllegalArgumentException for a cost that is not a power of two above 1, or r or p below
   *     1
   */
  public static byte[] derive(byte[] password, byte[] salt, int n, int r, int p, int length) {
    if (n < 2 || (n & (n - 1)) != 0) {
      throw new IllegalArgumentException("N must be a power of two greater than 1");
    }
    if (r < 1 || p < 1 || length < 1) {
      throw new IllegalArgumentException("r, p, and the key length must be at least 1");
    }
    int blockBytes = 128 * r;
    byte[] b = Crypto.pbkdf2Bytes(password, salt, 1, blockBytes * p);
    int words = 32 * r;
    int[] x = new int[words];
    int[] y = new int[words];
    int[] v = new int[words * n];
    for (int i = 0; i < p; i++) {
      roMix(b, i * blockBytes, x, y, v, n, r);
    }
    return Crypto.pbkdf2Bytes(password, b, 1, length);
  }

  /** scryptROMix: fills N blocks, then reads them back in an order that depends on each result. */
  private static void roMix(byte[] b, int offset, int[] x, int[] y, int[] v, int n, int r) {
    int words = 32 * r;
    for (int k = 0; k < words; k++) {
      int at = offset + k * 4;
      x[k] =
          (b[at] & 0xff)
              | (b[at + 1] & 0xff) << 8
              | (b[at + 2] & 0xff) << 16
              | (b[at + 3] & 0xff) << 24;
    }
    for (int i = 0; i < n; i++) {
      System.arraycopy(x, 0, v, i * words, words);
      blockMix(x, y, r);
      System.arraycopy(y, 0, x, 0, words);
    }
    int last = (2 * r - 1) * 16;
    int mask = n - 1;
    for (int i = 0; i < n; i++) {
      // Integerify: the first word of the last 64-byte part, the low bits of a little-endian
      // number.
      int j = x[last] & mask;
      int from = j * words;
      for (int k = 0; k < words; k++) {
        x[k] ^= v[from + k];
      }
      blockMix(x, y, r);
      System.arraycopy(y, 0, x, 0, words);
    }
    for (int k = 0; k < words; k++) {
      int at = offset + k * 4;
      b[at] = (byte) x[k];
      b[at + 1] = (byte) (x[k] >>> 8);
      b[at + 2] = (byte) (x[k] >>> 16);
      b[at + 3] = (byte) (x[k] >>> 24);
    }
  }

  /**
   * scryptBlockMix: 2r parts of 16 words, each mixed with the one before through Salsa20/8, the
   * even results first and the odd ones after.
   */
  private static void blockMix(int[] b, int[] out, int r) {
    int[] x = new int[16];
    System.arraycopy(b, (2 * r - 1) * 16, x, 0, 16);
    for (int k = 0; k < 2 * r; k++) {
      for (int w = 0; w < 16; w++) {
        x[w] ^= b[k * 16 + w];
      }
      salsa8(x);
      System.arraycopy(x, 0, out, ((k >> 1) + (k & 1) * r) * 16, 16);
    }
  }

  private static void salsa8(int[] b) {
    int x0 = b[0];
    int x1 = b[1];
    int x2 = b[2];
    int x3 = b[3];
    int x4 = b[4];
    int x5 = b[5];
    int x6 = b[6];
    int x7 = b[7];
    int x8 = b[8];
    int x9 = b[9];
    int x10 = b[10];
    int x11 = b[11];
    int x12 = b[12];
    int x13 = b[13];
    int x14 = b[14];
    int x15 = b[15];
    for (int round = 0; round < 4; round++) {
      // Columns.
      x4 ^= Integer.rotateLeft(x0 + x12, 7);
      x8 ^= Integer.rotateLeft(x4 + x0, 9);
      x12 ^= Integer.rotateLeft(x8 + x4, 13);
      x0 ^= Integer.rotateLeft(x12 + x8, 18);
      x9 ^= Integer.rotateLeft(x5 + x1, 7);
      x13 ^= Integer.rotateLeft(x9 + x5, 9);
      x1 ^= Integer.rotateLeft(x13 + x9, 13);
      x5 ^= Integer.rotateLeft(x1 + x13, 18);
      x14 ^= Integer.rotateLeft(x10 + x6, 7);
      x2 ^= Integer.rotateLeft(x14 + x10, 9);
      x6 ^= Integer.rotateLeft(x2 + x14, 13);
      x10 ^= Integer.rotateLeft(x6 + x2, 18);
      x3 ^= Integer.rotateLeft(x15 + x11, 7);
      x7 ^= Integer.rotateLeft(x3 + x15, 9);
      x11 ^= Integer.rotateLeft(x7 + x3, 13);
      x15 ^= Integer.rotateLeft(x11 + x7, 18);
      // Rows.
      x1 ^= Integer.rotateLeft(x0 + x3, 7);
      x2 ^= Integer.rotateLeft(x1 + x0, 9);
      x3 ^= Integer.rotateLeft(x2 + x1, 13);
      x0 ^= Integer.rotateLeft(x3 + x2, 18);
      x6 ^= Integer.rotateLeft(x5 + x4, 7);
      x7 ^= Integer.rotateLeft(x6 + x5, 9);
      x4 ^= Integer.rotateLeft(x7 + x6, 13);
      x5 ^= Integer.rotateLeft(x4 + x7, 18);
      x11 ^= Integer.rotateLeft(x10 + x9, 7);
      x8 ^= Integer.rotateLeft(x11 + x10, 9);
      x9 ^= Integer.rotateLeft(x8 + x11, 13);
      x10 ^= Integer.rotateLeft(x9 + x8, 18);
      x12 ^= Integer.rotateLeft(x15 + x14, 7);
      x13 ^= Integer.rotateLeft(x12 + x15, 9);
      x14 ^= Integer.rotateLeft(x13 + x12, 13);
      x15 ^= Integer.rotateLeft(x14 + x13, 18);
    }
    b[0] += x0;
    b[1] += x1;
    b[2] += x2;
    b[3] += x3;
    b[4] += x4;
    b[5] += x5;
    b[6] += x6;
    b[7] += x7;
    b[8] += x8;
    b[9] += x9;
    b[10] += x10;
    b[11] += x11;
    b[12] += x12;
    b[13] += x13;
    b[14] += x14;
    b[15] += x15;
  }
}
