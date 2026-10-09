package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/** CSV and ZIP output, byte for byte as the TypeScript SDK writes them. */
class ZipTest {
  /**
   * A cell back from its fixture form: {"js": "NaN"} and the like become the values JSON cannot
   * carry.
   */
  private static Object cell(Object cell) {
    if (cell instanceof Map<?, ?> map && map.size() == 1 && map.get("js") instanceof String js) {
      return switch (js) {
        case "undefined" -> Json.UNDEFINED;
        case "NaN" -> Double.NaN;
        case "Infinity" -> Double.POSITIVE_INFINITY;
        case "-Infinity" -> Double.NEGATIVE_INFINITY;
        case "-0" -> -0.0;
        default -> throw new IllegalArgumentException(js);
      };
    }
    if (cell instanceof List<?> list) {
      List<Object> out = new ArrayList<>();
      for (Object item : list) {
        out.add(cell(item));
      }
      return out;
    }
    return cell;
  }

  @Test
  void spreadsheetFormulasAreDefused() {
    assertEquals(
        "'=SUM(A1),'+1,-2,\"a,b\",\"say \"\"hi\"\"\",12",
        Zip.csvRow(List.of("=SUM(A1)", "+1", "-2", "a,b", "say \"hi\"", 12L)));
  }

  @Test
  void rows() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("zip"), "rows")) {
      List<Object> values = new ArrayList<>();
      values.add(cell(c.get("cell")));
      assertEquals(c.get("row"), Zip.csvRow(values), Fixtures.label(c.get("cell")));
    }
  }

  @Test
  @SuppressWarnings("unchecked")
  void csvs() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("zip"), "csvs")) {
      List<List<Object>> rows = new ArrayList<>();
      for (Object row : Js.list(c.get("rows"))) {
        rows.add((List<Object>) cell(row));
      }
      assertEquals(c.get("csv"), Zip.csv((List<String>) (List<?>) Js.list(c.get("header")), rows));
    }
  }

  @Test
  void zips() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("zip"), "zips")) {
      long now = Js.asLong(c.get("now"));
      assertEquals(
          HexFormat.of().formatHex(Base64.getDecoder().decode((String) c.get("base64"))),
          HexFormat.of().formatHex(Zip.zip(Fixtures.cases(c, "files"), now)),
          Fixtures.label(c.get("now")));
    }
  }

  @Test
  void aZipStartsLikeOne() {
    byte[] bytes = Zip.zip(List.of(Json.object("name", "overview.csv", "text", "a\r\n")), 0);
    String text = new String(bytes, StandardCharsets.ISO_8859_1);
    assertTrue(text.startsWith("PK\u0003\u0004"));
    assertTrue(text.contains("overview.csv"));
  }
}
