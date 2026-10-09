package sh.runlight.accounts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * Accounts' cryptography against tests/fixtures/crypto.json, written by the TypeScript SDK and
 * Node's own crypto.
 */
class CryptoTest {
  private static List<Map<String, Object>> cases(String key) {
    return Fixtures.cases(Fixtures.load("crypto"), key);
  }

  private static String hex(byte[] bytes) {
    return HexFormat.of().formatHex(bytes);
  }

  private static int integer(Object value) {
    return (int) Js.asLong(value);
  }

  @Test
  void scryptGivesNodesBytes() {
    for (Map<String, Object> c : cases("scrypt")) {
      byte[] key =
          Scrypt.derive(
              Js.utf8((String) c.get("password")),
              Crypto.fromBase64url((String) c.get("salt")),
              integer(c.get("N")),
              integer(c.get("r")),
              integer(c.get("p")),
              integer(c.get("length")));
      assertEquals(c.get("key"), hex(key), Fixtures.label(c));
    }
  }

  @Test
  void scryptTestVectorsFromRfc7914() {
    assertEquals(
        "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906",
        hex(Scrypt.derive(new byte[0], new byte[0], 16, 1, 1, 64)));
    assertEquals(
        "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640",
        hex(
            Scrypt.derive(
                "password".getBytes(StandardCharsets.UTF_8),
                "NaCl".getBytes(StandardCharsets.UTF_8),
                1024,
                8,
                16,
                64)));
  }

  @Test
  void scryptRefusesABadCost() {
    assertThrows(
        IllegalArgumentException.class,
        () -> Scrypt.derive(new byte[] {'x'}, new byte[] {'y'}, 1000, 8, 1, 32));
  }

  @Test
  void passwordsHashedByTypeScriptCheckHere() {
    List<Map<String, Object>> hashes = cases("hashes");
    for (int i = 0; i < hashes.size(); i++) {
      Map<String, Object> c = hashes.get(i);
      String password = (String) c.get("password");
      String hash = (String) c.get("hash");
      assertTrue(Crypto.checkPassword(password, hash), hash);
      if (i == 0) {
        assertFalse(Crypto.checkPassword(password + "!", hash));
      }
    }
  }

  @Test
  void newHashesUseScryptAndCheck() {
    String hash = Crypto.hashPassword("a long password");
    assertTrue(hash.matches("^scrypt\\$[A-Za-z0-9_-]{22}\\$[A-Za-z0-9_-]{43}\\z"), hash);
    assertTrue(Crypto.checkPassword("a long password", hash));
    assertNotEquals(hash, Crypto.hashPassword("a long password"), "a new salt each time");
  }

  @Test
  void checkPasswordAnswersAsTypeScriptDoes() {
    for (Map<String, Object> c : cases("checks")) {
      String password = (String) c.get("password");
      String stored = (String) c.get("stored");
      String label = password + " against " + stored;
      if (c.containsKey("throws")) {
        assertThrows(
            IllegalArgumentException.class, () -> Crypto.checkPassword(password, stored), label);
        continue;
      }
      assertEquals(c.get("value"), Crypto.checkPassword(password, stored), label);
    }
  }

  @Test
  void sealedTextOpensBothWays() {
    for (Map<String, Object> c : cases("sealedByTs")) {
      String text = (String) c.get("text");
      String secret = (String) c.get("secret");
      assertEquals(text, Crypto.unsealText((String) c.get("sealed"), secret));
      assertEquals(text, Crypto.unsealText(Crypto.sealText(text, secret), secret));
    }
    for (Map<String, Object> c : cases("sealedWithIv")) {
      assertEquals(
          c.get("sealed"),
          Crypto.sealText(
              (String) c.get("text"),
              (String) c.get("secret"),
              Crypto.fromBase64url((String) c.get("iv"))));
    }
  }

  @Test
  void unsealAnswersAsTypeScriptDoes() {
    for (Map<String, Object> c : cases("unseal")) {
      assertEquals(
          c.get("result"),
          Crypto.unsealText((String) c.get("sealed"), (String) c.get("secret")),
          Fixtures.label(c));
    }
  }

  @Test
  void base64AndBase32() {
    for (Map<String, Object> c : cases("base64")) {
      String text = (String) c.get("text");
      if (c.containsKey("throws")) {
        assertThrows(
            IllegalArgumentException.class, () -> Crypto.fromBase64url(text), text + " throws");
        continue;
      }
      assertEquals(c.get("value"), hex(Crypto.fromBase64url(text)), text);
    }
    for (Map<String, Object> c : cases("encode")) {
      byte[] bytes = HexFormat.of().parseHex((String) c.get("hex"));
      assertEquals(c.get("base64url"), Crypto.base64url(bytes));
      assertEquals(c.get("base32"), Crypto.base32(bytes));
      assertEquals(c.get("hex"), hex(Crypto.fromBase64url((String) c.get("base64url"))));
      assertEquals(c.get("hex"), hex(Crypto.unbase32((String) c.get("base32"))));
    }
  }

  @Test
  void totpCodes() {
    for (Map<String, Object> c : cases("totp")) {
      String secret = (String) c.get("secret");
      long step = (long) Js.asDouble(c.get("step"));
      String label = secret + " at " + Json.stringify(c.get("step"));
      if (c.containsKey("throws")) {
        assertThrows(IllegalArgumentException.class, () -> Crypto.totp(secret, step), label);
        continue;
      }
      assertEquals(c.get("value"), Crypto.totp(secret, step), label);
    }
  }

  @Test
  void rfc6238Vector() {
    // RFC 6238's SHA-1 secret "12345678901234567890" at 59 seconds: 94287082, of which
    // authenticator apps show the last six.
    String secret = Crypto.base32("12345678901234567890".getBytes(StandardCharsets.UTF_8));
    assertEquals("287082", Crypto.totp(secret, 1));
    assertEquals("005924", Crypto.totp(secret, 1234567890L / 30));
  }

  @Test
  void matchStepAllowsOneStepEitherSideAndNeverAnOldOne() {
    String secret = "JBSWY3DPEHPK3PXP";
    long now = 1_759_900_000_000L;
    long step = now / Crypto.STEP_MS;
    assertEquals(step, Crypto.matchStep(secret, Crypto.totp(secret, step), now, 0));
    assertEquals(step - 1, Crypto.matchStep(secret, Crypto.totp(secret, step - 1), now, 0));
    assertEquals(step + 1, Crypto.matchStep(secret, Crypto.totp(secret, step + 1), now, 0));
    assertNull(Crypto.matchStep(secret, Crypto.totp(secret, step + 2), now, 0));
    assertNull(
        Crypto.matchStep(secret, Crypto.totp(secret, step), now, step),
        "a code used once is not taken again");
  }

  @Test
  void otpauthSignaturesRecoveryAndSameText() {
    for (Map<String, Object> c : cases("uris")) {
      assertEquals(
          c.get("uri"),
          Crypto.otpauthUri(
              (String) c.get("secret"), (String) c.get("email"), (String) c.get("host")));
    }
    for (Map<String, Object> c : cases("signatures")) {
      assertEquals(
          c.get("signature"),
          Crypto.signature(
              (String) c.get("secret"), (String) c.get("body"), (String) c.get("hash")));
    }
    for (Map<String, Object> c : cases("recovery")) {
      assertEquals(c.get("hash"), Crypto.recoveryHash((String) c.get("code")), Fixtures.label(c));
    }
    for (Map<String, Object> c : cases("same")) {
      assertEquals(c.get("same"), Crypto.sameText((String) c.get("a"), (String) c.get("b")));
    }
    List<String> codes = Crypto.recoveryCodes();
    assertEquals(10, codes.size());
    for (String code : codes) {
      assertTrue(code.matches("^[a-z2-7]{4}-[a-z2-7]{4}\\z"), code);
    }
  }
}
