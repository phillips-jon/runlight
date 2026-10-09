package sh.runlight;

import java.security.InvalidKeyException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.HexFormat;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** SHA-256, HMAC, the day's visitor hash, and random ids. */
public final class Hash {
  private Hash() {}

  private static final SecureRandom RANDOM = new SecureRandom();

  public static String sha256(String text) {
    return HexFormat.of().formatHex(sha256Bytes(Js.utf8(text)));
  }

  public static byte[] sha256Bytes(byte[] bytes) {
    try {
      return MessageDigest.getInstance("SHA-256").digest(bytes);
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException(e);
    }
  }

  /** HMAC-SHA-256 of text under key, as hex. */
  public static String hmac(String key, String text) {
    return HexFormat.of().formatHex(hmacBytes(Js.utf8(key), Js.utf8(text)));
  }

  public static byte[] hmacBytes(byte[] key, byte[] text) {
    try {
      Mac mac = Mac.getInstance("HmacSHA256");
      // An empty key, which SecretKeySpec refuses, is the same as one zero byte once padded.
      mac.init(new SecretKeySpec(key.length == 0 ? new byte[1] : key, "HmacSHA256"));
      return mac.doFinal(text);
    } catch (NoSuchAlgorithmException | InvalidKeyException e) {
      throw new IllegalStateException(e);
    }
  }

  /**
   * The day's visitor hash: SHA-256 of salt, site, IP, and user agent, cut to 64 bits. The salt
   * changes every day and old salts are deleted, so the hash cannot be recomputed and does not
   * follow anyone across days.
   */
  public static String visitorHash(String salt, String site, String ip, String ua) {
    return sha256(salt + "\n" + site + "\n" + ip + "\n" + ua).substring(0, 16);
  }

  public static String randomId() {
    return randomId(12);
  }

  public static String randomId(int bytes) {
    return HexFormat.of().formatHex(randomBytes(bytes));
  }

  public static byte[] randomBytes(int count) {
    byte[] out = new byte[count];
    RANDOM.nextBytes(out);
    return out;
  }

  public static String randomSalt() {
    return randomId(32);
  }
}
