package sh.runlight.conformance;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.zip.DataFormatException;
import java.util.zip.Inflater;
import sh.runlight.Js;
import sh.runlight.Json;

/** ZIP reading as http-conformance.ts does it: the files, stored or deflated, by local headers. */
public final class Unzip {
  private Unzip() {}

  public static List<Map<String, Object>> unzip(byte[] bytes) {
    List<Map<String, Object>> files = new ArrayList<>();
    ByteBuffer b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
    int at = 0;
    while (at + 30 <= bytes.length && b.getInt(at) == 0x04034b50) {
      int method = b.getShort(at + 8) & 0xFFFF;
      int size = b.getInt(at + 18);
      int nameLength = b.getShort(at + 26) & 0xFFFF;
      int extra = b.getShort(at + 28) & 0xFFFF;
      String name = Js.decodeUtf8(Arrays.copyOfRange(bytes, at + 30, at + 30 + nameLength));
      int start = at + 30 + nameLength + extra;
      byte[] data = Arrays.copyOfRange(bytes, start, start + size);
      if (method == 8) {
        data = inflate(data, name);
      }
      files.add(Json.object("name", name, "text", Js.decodeUtf8(data)));
      at = start + size;
    }
    return files;
  }

  private static byte[] inflate(byte[] data, String name) {
    Inflater inflater = new Inflater(true);
    inflater.setInput(data);
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    byte[] chunk = new byte[8192];
    try {
      while (!inflater.finished()) {
        int n = inflater.inflate(chunk);
        if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) {
          break;
        }
        out.write(chunk, 0, n);
      }
    } catch (DataFormatException e) {
      throw new IllegalStateException("The ZIP's " + name + " does not inflate", e);
    } finally {
      inflater.end();
    }
    return out.toByteArray();
  }
}
