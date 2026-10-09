package sh.runlight.accounts;

import java.nio.ByteBuffer;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.List;
import java.util.regex.Pattern;
import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import sh.runlight.Js;

/**
 * The cryptography accounts need. Passwords use scrypt, as the standalone server always has, in a
 * plain Java scrypt that gives the same bytes as Node's; a PBKDF2 hash made on an edge runtime
 * checks out too.
 *
 * <p>Bytes are byte arrays throughout, and text is hashed as UTF-8, a lone surrogate as U+FFFD, as
 * TextEncoder writes it. The two-factor pieces that live in auth.ts in TypeScript (base32, TOTP,
 * the otpauth address, recovery codes, and the signature on session cookies) are here too, as
 * functions of their inputs alone, so the accounts class can call them.
 */
public final class Crypto {
  private Crypto() {}

  private static final int SCRYPT_N = 16384;
  private static final int SCRYPT_R = 8;
  private static final int SCRYPT_P = 1;

  /** As many PBKDF2 rounds as Cloudflare Workers allow, the strictest runtime Runlight runs on. */
  public static final int PBKDF2_ROUNDS = 100_000;

  // Two-factor: TOTP as authenticator apps expect it (RFC 6238): SHA-1, six digits, 30 seconds.
  public static final long STEP_MS = 30_000;
  private static final String BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

  /** The shortest stored key accepted. Ours are 32 bytes. */
  public static final int MIN_KEY_BYTES = 16;

  private static final SecureRandom RANDOM = new SecureRandom();
  private static final Pattern BASE64 = Pattern.compile("^[A-Za-z0-9+/]*\\z");
  private static final String BASE64_LETTERS =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  public static byte[] randomBytes(int length) {
    byte[] out = new byte[length];
    RANDOM.nextBytes(out);
    return out;
  }

  public static String base64url(byte[] bytes) {
    return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
  }

  /**
   * Bytes from base64url (or plain base64), read as atob() reads them: white space is skipped,
   * padding is optional, and anything else that is not base64 throws.
   *
   * @throws IllegalArgumentException for text atob() refuses
   */
  public static byte[] fromBase64url(String text) {
    StringBuilder plain = new StringBuilder(text.length());
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      if (c == '\t' || c == '\n' || c == '\f' || c == '\r' || c == ' ') {
        continue;
      }
      plain.append(c == '-' ? '+' : c == '_' ? '/' : c);
    }
    String s = plain.toString();
    if (s.length() % 4 == 0) {
      if (s.endsWith("==")) {
        s = s.substring(0, s.length() - 2);
      } else if (s.endsWith("=")) {
        s = s.substring(0, s.length() - 1);
      }
    }
    if (s.length() % 4 == 1 || !BASE64.matcher(s).matches()) {
      throw new IllegalArgumentException("The string to be decoded is not correctly encoded.");
    }
    byte[] out = new byte[s.length() * 3 / 4];
    int bits = 0;
    int value = 0;
    int at = 0;
    for (int i = 0; i < s.length(); i++) {
      value = (value << 6) | BASE64_LETTERS.indexOf(s.charAt(i));
      bits += 6;
      if (bits >= 8) {
        out[at++] = (byte) (value >> (bits - 8));
        bits -= 8;
        value &= (1 << bits) - 1;
      }
    }
    return at == out.length ? out : Arrays.copyOf(out, at);
  }

  public static String hex(byte[] bytes) {
    return HexFormat.of().formatHex(bytes);
  }

  /** SHA-256 of text, as UTF-8. */
  public static byte[] sha256(String value) {
    return sha256(Js.utf8(value));
  }

  public static byte[] sha256(byte[] value) {
    try {
      return MessageDigest.getInstance("SHA-256").digest(value);
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException(e);
    }
  }

  /**
   * HMAC of data under a key, with "SHA-1" or "SHA-256".
   *
   * @throws IllegalArgumentException for an empty key, which WebCrypto will not import
   */
  public static byte[] hmac(String hash, byte[] key, byte[] data) {
    if (key.length == 0) {
      // WebCrypto will not import an empty HMAC key.
      throw new IllegalArgumentException("An HMAC key must not be empty");
    }
    return mac(hash.equals("SHA-1") ? "HmacSHA1" : "HmacSHA256", key, data);
  }

  /** HMAC with text for the key and the data, each as UTF-8. */
  public static byte[] hmac(String hash, String key, String data) {
    return hmac(hash, Js.utf8(key), Js.utf8(data));
  }

  private static byte[] mac(String algorithm, byte[] key, byte[] data) {
    try {
      Mac mac = Mac.getInstance(algorithm);
      mac.init(new SecretKeySpec(key, algorithm));
      return mac.doFinal(data);
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException(e);
    }
  }

  /** Compares two strings in time that does not depend on where they differ. */
  public static boolean sameText(String a, String b) {
    return sameBytes(Js.utf8(a), Js.utf8(b));
  }

  /** A password hash, in the scrypt form the standalone server has always written. */
  public static String hashPassword(String password) {
    byte[] salt = randomBytes(16);
    return "scrypt$" + base64url(salt) + "$" + base64url(scrypt(password, salt, 32));
  }

  /**
   * Whether a password matches a hash, scrypt or PBKDF2. A stored key under MIN_KEY_BYTES is
   * refused, since an empty or cut key would match too easily, or anything.
   *
   * @throws IllegalArgumentException when a part of the hash is not base64, as the TypeScript
   *     rejects then
   */
  public static boolean checkPassword(String password, String stored) {
    String[] parts = stored.split("\\$", -1);
    // A stored hash whose salt or key is not base64url matches nothing, rather than failing the
    // sign-in.
    if (parts[0].equals("scrypt") && parts.length == 3) {
      byte[] expected = decode(parts[2]);
      byte[] salt = decode(parts[1]);
      if (expected == null || salt == null || expected.length < MIN_KEY_BYTES) {
        return false;
      }
      return sameBytes(scrypt(password, salt, expected.length), expected);
    }
    if (parts[0].equals("pbkdf2") && parts.length == 4) {
      double rounds = Js.toNumber(parts[1]);
      if (!Js.isInteger(rounds) || rounds < 1 || rounds > 10_000_000) {
        return false;
      }
      byte[] expected = decode(parts[3]);
      byte[] salt = decode(parts[2]);
      if (expected == null || salt == null || expected.length < MIN_KEY_BYTES) {
        return false;
      }
      return sameBytes(
          pbkdf2Bytes(Js.utf8(password), salt, (int) rounds, expected.length), expected);
    }
    return false;
  }

  /** Bytes from base64url, or null for text that is not base64url. */
  private static byte[] decode(String text) {
    try {
      return fromBase64url(text);
    } catch (IllegalArgumentException e) {
      return null;
    }
  }

  private static byte[] scrypt(String password, byte[] salt, int length) {
    return length == 0
        ? new byte[0]
        : Scrypt.derive(Js.utf8(password), salt, SCRYPT_N, SCRYPT_R, SCRYPT_P, length);
  }

  /** PBKDF2 with HMAC-SHA-256 over bytes, an empty password included, as WebCrypto derives it. */
  static byte[] pbkdf2Bytes(byte[] password, byte[] salt, int rounds, int length) {
    byte[] out = new byte[length];
    if (length == 0) {
      return out;
    }
    try {
      Mac mac = Mac.getInstance("HmacSHA256");
      // An empty key, which SecretKeySpec refuses, is the same as one zero byte once padded.
      mac.init(new SecretKeySpec(password.length == 0 ? new byte[1] : password, "HmacSHA256"));
      int blocks = (length + 31) / 32;
      for (int block = 1; block <= blocks; block++) {
        mac.update(salt);
        mac.update(ByteBuffer.allocate(4).putInt(block).array());
        byte[] u = mac.doFinal();
        byte[] t = u.clone();
        for (int i = 1; i < rounds; i++) {
          u = mac.doFinal(u);
          for (int k = 0; k < t.length; k++) {
            t[k] ^= u[k];
          }
        }
        int at = (block - 1) * 32;
        System.arraycopy(t, 0, out, at, Math.min(32, length - at));
      }
      return out;
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException(e);
    }
  }

  private static boolean sameBytes(byte[] a, byte[] b) {
    int diff = a.length ^ b.length;
    int length = Math.max(a.length, b.length);
    for (int i = 0; i < length; i++) {
      diff |= (i < a.length ? a[i] & 0xff : 0) ^ (i < b.length ? b[i] & 0xff : 0);
    }
    return diff == 0;
  }

  private static SecretKeySpec sealKey(String secret) {
    return new SecretKeySpec(sha256("totp:" + secret), "AES");
  }

  /**
   * Seals text with AES-256-GCM under a key from the secret, as "iv.body.tag" in base64url, the
   * form the standalone server has always stored two-factor secrets in.
   */
  public static String sealText(String text, String secret) {
    return sealText(text, secret, randomBytes(12));
  }

  /** As {@link #sealText(String, String)} with a given IV, for tests. */
  public static String sealText(String text, String secret, byte[] iv) {
    try {
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(Cipher.ENCRYPT_MODE, sealKey(secret), new GCMParameterSpec(128, iv));
      byte[] out = cipher.doFinal(Js.utf8(text));
      return base64url(iv)
          + "."
          + base64url(Arrays.copyOfRange(out, 0, out.length - 16))
          + "."
          + base64url(Arrays.copyOfRange(out, out.length - 16, out.length));
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException("AES-GCM sealing failed", e);
    }
  }

  /** The text sealed by {@link #sealText}, or null when it does not open under the secret. */
  public static String unsealText(String sealed, String secret) {
    try {
      String[] parts = sealed.split("\\.", -1);
      String iv = parts[0];
      String body = parts.length > 1 ? parts[1] : null;
      String tag = parts.length > 2 ? parts[2] : null;
      if (iv.isEmpty() || body == null || tag == null || tag.isEmpty()) {
        return null;
      }
      // WebCrypto reads the tag as the last 16 bytes of body and tag together, wherever the dot
      // fell.
      byte[] bodyBytes = fromBase64url(body);
      byte[] tagBytes = fromBase64url(tag);
      byte[] joined = Arrays.copyOf(bodyBytes, bodyBytes.length + tagBytes.length);
      System.arraycopy(tagBytes, 0, joined, bodyBytes.length, tagBytes.length);
      byte[] ivBytes = fromBase64url(iv);
      // WebCrypto refuses an IV shorter than 12 bytes.
      if (joined.length < 16 || ivBytes.length < 12) {
        return null;
      }
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(Cipher.DECRYPT_MODE, sealKey(secret), new GCMParameterSpec(128, ivBytes));
      return Js.decodeUtf8(cipher.doFinal(joined));
    } catch (GeneralSecurityException | RuntimeException e) {
      return null;
    }
  }

  public static String base32(byte[] bytes) {
    int bits = 0;
    int value = 0;
    StringBuilder out = new StringBuilder();
    for (byte b : bytes) {
      // Only the low bits are ever read, so the rest are dropped before they grow.
      value = ((value << 8) | (b & 0xff)) & 0xffff;
      bits += 8;
      while (bits >= 5) {
        out.append(BASE32.charAt((value >> (bits - 5)) & 31));
        bits -= 5;
      }
    }
    if (bits > 0) {
      out.append(BASE32.charAt((value << (5 - bits)) & 31));
    }
    return out.toString();
  }

  /**
   * Bytes from base32, skipping anything that is not a base32 letter, as authenticator apps'
   * secrets come.
   */
  public static byte[] unbase32(String text) {
    int bits = 0;
    int value = 0;
    java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
    String upper = Js.upper(text.replaceAll("=+\\z", ""));
    for (int k = 0; k < upper.length(); k++) {
      // A surrogate is never a base32 letter, so going by UTF-16 units skips what code points
      // would.
      int i = BASE32.indexOf(upper.charAt(k));
      if (i < 0) {
        continue;
      }
      value = ((value << 5) | i) & 0xffff;
      bits += 5;
      if (bits >= 8) {
        out.write((value >> (bits - 8)) & 255);
        bits -= 8;
      }
    }
    return out.toByteArray();
  }

  /**
   * The six-digit code for a secret at a time step.
   *
   * @throws IllegalArgumentException for a secret with no whole byte in it, as WebCrypto refuses
   *     its empty key
   */
  public static String totp(String secret, long step) {
    byte[] mac = hmac("SHA-1", unbase32(secret), ByteBuffer.allocate(8).putLong(step).array());
    int at = mac[19] & 15;
    int n =
        (mac[at] & 127) << 24
            | (mac[at + 1] & 0xff) << 16
            | (mac[at + 2] & 0xff) << 8
            | (mac[at + 3] & 0xff);
    String code = Integer.toString(n % 1_000_000);
    return "0".repeat(6 - code.length()) + code;
  }

  /**
   * The time step a code matches, one step either side for clocks that drift, newer than {@code
   * after}; else null.
   */
  public static Long matchStep(String secret, String code, long now, long after) {
    long current = Math.floorDiv(now, STEP_MS);
    for (long step : new long[] {current, current - 1, current + 1}) {
      if (step > after && totp(secret, step).equals(code)) {
        return step;
      }
    }
    return null;
  }

  /** The address an authenticator app reads from the QR code. */
  public static String otpauthUri(String secret, String email, String host) {
    String label = Js.encodeURIComponent("Runlight (" + host + "):" + email);
    return "otpauth://totp/"
        + label
        + "?secret="
        + secret
        + "&issuer="
        + Js.encodeURIComponent("Runlight (" + host + ")")
        + "&algorithm=SHA1&digits=6&period=30";
  }

  /** Ten one-use recovery codes, like "k7dq-2mfa". */
  public static List<String> recoveryCodes() {
    List<String> codes = new ArrayList<>();
    for (int i = 0; i < 10; i++) {
      String raw = Js.lower(base32(randomBytes(5)));
      codes.add(raw.substring(0, 4) + "-" + raw.substring(4, 8));
    }
    return codes;
  }

  /**
   * What a recovery code is kept as: SHA-256 of its letters and digits in lower case, so dashes and
   * case do not matter.
   */
  public static String recoveryHash(String code) {
    return hex(sha256(Js.lower(code.replaceAll("[^a-zA-Z0-9]", ""))));
  }

  /**
   * The signature on a session, sign-in, or device value: HMAC-SHA-256 of "body.hash" under the
   * install's secret.
   */
  public static String signature(String secret, String body, String hash) {
    return base64url(hmac("SHA-256", secret, body + "." + hash));
  }
}
