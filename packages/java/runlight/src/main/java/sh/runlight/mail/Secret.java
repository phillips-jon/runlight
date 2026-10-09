package sh.runlight.mail;

import java.security.GeneralSecurityException;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import sh.runlight.Hash;
import sh.runlight.Js;

/**
 * Keys kept in the database (the mail service's, the AI Assistant's, and the tokens for connected
 * installs) are encrypted with AES-GCM, under a key derived from a secret only the server has:
 * {@code RUNLIGHT_SECRET}, or else the dashboard token. A copied database alone does not give them
 * away. The label says "mail" because mail came first; changing it would make every saved key
 * unreadable.
 *
 * <p>The sealed form is Web Crypto's: base64 of the 12 byte IV, and base64 of the ciphertext
 * followed by its 16 byte tag, so every implementation opens what another sealed.
 */
public final class Secret {
  private Secret() {}

  private static SecretKeySpec keyFor(String secret) {
    return new SecretKeySpec(Hash.sha256Bytes(Js.utf8("runlight-mail:" + secret)), "AES");
  }

  /** {@code v1:<iv>:<ciphertext>}, or {@code plain:<json>} when there is no secret to use. */
  public static String seal(String value, String secret) {
    if (secret == null || secret.isEmpty()) {
      return "plain:" + value;
    }
    byte[] iv = Hash.randomBytes(12);
    try {
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(Cipher.ENCRYPT_MODE, keyFor(secret), new GCMParameterSpec(128, iv));
      byte[] data = cipher.doFinal(Js.utf8(value));
      Base64.Encoder base64 = Base64.getEncoder();
      return "v1:" + base64.encodeToString(iv) + ":" + base64.encodeToString(data);
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException("AES-GCM is not available", e);
    }
  }

  /** The sealed value, or null when it cannot be opened (a different secret, or damaged). */
  public static String unseal(String sealed, String secret) {
    if (sealed.startsWith("plain:")) {
      return sealed.substring(6);
    }
    String[] parts = sealed.split(":", -1);
    String version = parts[0];
    String iv = parts.length > 1 ? parts[1] : "";
    String data = parts.length > 2 ? parts[2] : "";
    if (!version.equals("v1")
        || iv.isEmpty()
        || data.isEmpty()
        || secret == null
        || secret.isEmpty()) {
      return null;
    }
    try {
      byte[] ivBytes = Base64.getDecoder().decode(iv);
      byte[] dataBytes = Base64.getDecoder().decode(data);
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(Cipher.DECRYPT_MODE, keyFor(secret), new GCMParameterSpec(128, ivBytes));
      return Js.decodeUtf8(cipher.doFinal(dataBytes));
    } catch (GeneralSecurityException | IllegalArgumentException e) {
      return null;
    }
  }
}
