package sh.runlight;

/**
 * IP address literals read as inet_pton reads them: four dotted decimal bytes, or eight groups of
 * hex with one {@code ::} and an optional dotted IPv4 tail. Never a host name, so nothing here
 * looks anything up.
 */
public final class Ip {
  private Ip() {}

  /** The address's 4 or 16 bytes, or null when the text is not an address. */
  public static byte[] parse(String text) {
    if (text == null || text.isEmpty()) {
      return null;
    }
    if (text.indexOf(':') < 0) {
      return v4(text);
    }
    return v6(text);
  }

  /** Whether the text is an IPv4 or IPv6 address, as node:net's isIP sees it (without zones). */
  public static int version(String text) {
    byte[] bytes = parse(text);
    return bytes == null ? 0 : bytes.length == 4 ? 4 : 6;
  }

  private static byte[] v4(String text) {
    String[] parts = text.split("\\.", -1);
    if (parts.length != 4) {
      return null;
    }
    byte[] out = new byte[4];
    for (int i = 0; i < 4; i++) {
      String part = parts[i];
      if (part.isEmpty() || part.length() > 3) {
        return null;
      }
      int value = 0;
      for (int k = 0; k < part.length(); k++) {
        char c = part.charAt(k);
        if (c < '0' || c > '9') {
          return null;
        }
        value = value * 10 + (c - '0');
      }
      if (value > 255 || (part.length() > 1 && part.charAt(0) == '0')) {
        return null;
      }
      out[i] = (byte) value;
    }
    return out;
  }

  private static byte[] v6(String text) {
    int split = text.indexOf("::");
    if (split >= 0 && text.indexOf("::", split + 1) >= 0) {
      return null;
    }
    String head = split < 0 ? text : text.substring(0, split);
    String tail = split < 0 ? "" : text.substring(split + 2);
    int[] headGroups = groups(head, split < 0);
    int[] tailGroups = split < 0 ? new int[0] : groups(tail, true);
    if (headGroups == null || tailGroups == null) {
      return null;
    }
    int total = headGroups.length + tailGroups.length;
    if (split < 0 ? total != 8 : total > 7) {
      return null;
    }
    byte[] out = new byte[16];
    for (int i = 0; i < headGroups.length; i++) {
      out[2 * i] = (byte) (headGroups[i] >> 8);
      out[2 * i + 1] = (byte) headGroups[i];
    }
    int start = 8 - tailGroups.length;
    for (int i = 0; i < tailGroups.length; i++) {
      out[2 * (start + i)] = (byte) (tailGroups[i] >> 8);
      out[2 * (start + i) + 1] = (byte) tailGroups[i];
    }
    return out;
  }

  /** The 16 bit groups of one side of {@code ::}; the last may be a dotted IPv4 address. */
  private static int[] groups(String text, boolean mayEndInV4) {
    if (text.isEmpty()) {
      return new int[0];
    }
    String[] parts = text.split(":", -1);
    int count = parts.length;
    String last = parts[count - 1];
    boolean v4 = mayEndInV4 && last.indexOf('.') >= 0;
    int[] out = new int[v4 ? count + 1 : count];
    for (int i = 0; i < (v4 ? count - 1 : count); i++) {
      String part = parts[i];
      if (part.isEmpty() || part.length() > 4) {
        return null;
      }
      int value = 0;
      for (int k = 0; k < part.length(); k++) {
        int digit = Character.digit(part.charAt(k), 16);
        if (digit < 0 || part.charAt(k) > 127) {
          return null;
        }
        value = value * 16 + digit;
      }
      out[i] = value;
    }
    if (v4) {
      byte[] tail = v4(last);
      if (tail == null) {
        return null;
      }
      out[count - 1] = ((tail[0] & 0xFF) << 8) | (tail[1] & 0xFF);
      out[count] = ((tail[2] & 0xFF) << 8) | (tail[3] & 0xFF);
    }
    return out;
  }
}
