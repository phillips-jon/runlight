package sh.runlight;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import java.util.zip.CRC32;

/**
 * A ZIP file of text files, stored without compression, and the CSV that goes in it. Small and
 * plain, so it needs no library.
 */
public final class Zip {
  private Zip() {}

  private static final Pattern FORMULA = Pattern.compile("^[=+\\-@\\t\\r]");
  private static final Pattern PLAIN_NUMBER = Pattern.compile("^-?\\d+(\\.\\d+)?\\z");
  private static final Pattern QUOTE = Pattern.compile("[\",\\n\\r]");

  /** DOS date and time, as ZIP stores them: {time, day}. */
  private static int[] dosTime(long ms) {
    ZonedDateTime at = Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC);
    return new int[] {
      ((at.getHour() << 11) | (at.getMinute() << 5) | (at.getSecond() / 2)) & 0xFFFF,
      (((at.getYear() - 1980) << 9) | (at.getMonthValue() << 5) | at.getDayOfMonth()) & 0xFFFF
    };
  }

  /** The ZIP's bytes, every entry carrying the time now. */
  public static byte[] zip(List<Map<String, Object>> files) {
    return zip(files, System.currentTimeMillis());
  }

  /**
   * The ZIP's bytes. Every entry ({@code name} and {@code text}) carries the time {@code now}
   * (epoch milliseconds, as the TypeScript's Date), in UTC.
   */
  public static byte[] zip(List<Map<String, Object>> files, long now) {
    int[] dos = dosTime(now);
    int time = dos[0];
    int day = dos[1];
    ByteArrayOutputStream parts = new ByteArrayOutputStream();
    ByteArrayOutputStream central = new ByteArrayOutputStream();
    long offset = 0;
    for (Map<String, Object> file : files) {
      // TextEncoder writes UTF-8, with U+FFFD for anything that is not text.
      byte[] name = Js.utf8((String) file.get("name"));
      byte[] data = Js.utf8((String) file.get("text"));
      CRC32 crc32 = new CRC32();
      crc32.update(data);
      int crc = (int) crc32.getValue();

      ByteBuffer local = ByteBuffer.allocate(30).order(ByteOrder.LITTLE_ENDIAN);
      local.putInt(0x04034b50);
      local.putShort((short) 20);
      local.putShort((short) 0x0800); // names are UTF-8
      local.putShort((short) 0); // stored
      local.putShort((short) time);
      local.putShort((short) day);
      local.putInt(crc);
      local.putInt(data.length);
      local.putInt(data.length);
      local.putShort((short) name.length);
      local.putShort((short) 0);
      parts.writeBytes(local.array());
      parts.writeBytes(name);
      parts.writeBytes(data);

      ByteBuffer entry = ByteBuffer.allocate(46).order(ByteOrder.LITTLE_ENDIAN);
      entry.putInt(0x02014b50);
      entry.putShort((short) 20);
      entry.putShort((short) 20);
      entry.putShort((short) 0x0800);
      entry.putShort((short) 0);
      entry.putShort((short) time);
      entry.putShort((short) day);
      entry.putInt(crc);
      entry.putInt(data.length);
      entry.putInt(data.length);
      entry.putShort((short) name.length);
      entry.putInt(42, (int) offset);
      central.writeBytes(entry.array());
      central.writeBytes(name);
      offset += 30 + name.length + data.length;
    }
    ByteBuffer end = ByteBuffer.allocate(22).order(ByteOrder.LITTLE_ENDIAN);
    end.putInt(0x06054b50);
    end.putShort(8, (short) files.size());
    end.putShort(10, (short) files.size());
    end.putInt(12, central.size());
    end.putInt(16, (int) offset);
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    out.writeBytes(parts.toByteArray());
    out.writeBytes(central.toByteArray());
    out.writeBytes(end.array());
    return out.toByteArray();
  }

  /**
   * One CSV row, quoting what needs it; a leading =, +, -, or @ is escaped so a spreadsheet will
   * not run it.
   */
  public static String csvRow(List<?> values) {
    List<String> cells = new ArrayList<>();
    for (Object v : values) {
      String s = v == null || v == Json.UNDEFINED ? "" : Js.string(v);
      if (FORMULA.matcher(s).find() && !PLAIN_NUMBER.matcher(s).find()) {
        s = "'" + s;
      }
      cells.add(QUOTE.matcher(s).find() ? "\"" + s.replace("\"", "\"\"") + "\"" : s);
    }
    return String.join(",", cells);
  }

  public static String csv(List<String> header, List<? extends List<?>> rows) {
    List<String> lines = new ArrayList<>();
    lines.add(csvRow(header));
    for (List<?> row : rows) {
      lines.add(csvRow(row));
    }
    return String.join("\r\n", lines) + "\r\n";
  }
}
