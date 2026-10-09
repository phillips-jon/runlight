package sh.runlight.importers;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BiFunction;
import java.util.function.LongSupplier;
import sh.runlight.Js;
import sh.runlight.Json;

/** Link imports from other shorteners, a step at a time. */
public final class Index {
  private Index() {}

  /** The sources a link import can read, by name, each made from an Http and a clock. */
  public static final Map<String, BiFunction<Http, LongSupplier, Importer>> IMPORTERS;

  static {
    Map<String, BiFunction<Http, LongSupplier, Importer>> importers = new LinkedHashMap<>();
    importers.put("umami", Umami::new);
    importers.put("dub", Dub::new);
    importers.put("bitly", Bitly::new);
    importers.put("shortio", Shortio::new);
    importers.put("rebrandly", Rebrandly::new);
    IMPORTERS = Collections.unmodifiableMap(importers);
  }

  /**
   * One step of an import: fetch the next few links from the source, write each with its history,
   * and report progress. The cursor carries where to pick up, so the page calls this until the
   * cursor comes back null.
   *
   * <p>Each importer makes its requests through the Runlight's fetcher, and reads the Runlight's
   * clock as its {@code now}: the date of a link the source gives none for, and where Umami's
   * history ends.
   *
   * @return an ImportStep: {@code cursor}, {@code done}, {@code total}, {@code links}, {@code
   *     clicks}, {@code skipped}, and {@code failed} (each {@code {slug, reason, code?, params?}})
   */
  public static Map<String, Object> importStep(
      Host runlight,
      String site,
      String source,
      Map<String, String> credentials,
      String cursor,
      double done) {
    BiFunction<Http, LongSupplier, Importer> make = IMPORTERS.get(source);
    if (make == null) {
      throw new ImportError(
          "Runlight cannot import from " + source, "import_source", Json.object("source", source));
    }
    runlight.init();
    Importer importer = make.apply(new Http(runlight.fetcher()), runlight::now);
    Importer.Known known =
        (sourceId, slug, url) -> {
          if (runlight.store().linkById(Write.importedLinkId(source, Js.string(sourceId)))
              != null) {
            return true;
          }
          if (!Js.truthy(slug) || !Js.truthy(url)) {
            return false;
          }
          Map<String, Object> taken = runlight.store().linkBySlug(Js.string(slug));
          return taken != null && Write.sameUrl((String) taken.get("url"), Js.string(url));
        };
    Map<String, Object> result = importer.step(credentials, cursor, known);
    double stepDone = done;
    long links = 0;
    long clicks = 0;
    long skipped = 0;
    List<Object> failed = new ArrayList<>();
    for (Object entry : Js.list(result.get("links"))) {
      Map<String, Object> item = Js.map(entry);
      if (Js.truthy(item.get("known"))) {
        stepDone++;
        skipped++;
        continue;
      }
      Map<String, Object> written =
          Write.writeLink(runlight, site, source, Js.map(item.get("link")), item);
      stepDone++;
      Object status = written.get("status");
      if ("created".equals(status)) {
        links++;
        clicks += Js.asLong(written.get("clicks"));
      } else if ("skipped".equals(status)) {
        skipped++;
      } else {
        Map<String, Object> failure =
            Json.object(
                "slug",
                Js.get(item.get("link"), "slug"),
                "reason",
                Http.coalesce(written.get("reason"), ""));
        if (Js.truthy(written.get("code"))) {
          failure.put("code", written.get("code"));
          failure.put("params", Http.coalesce(written.get("params"), Json.object()));
        }
        failed.add(failure);
      }
    }
    // A total that is not a number is as good as none.
    Object total =
        result.get("total") instanceof Number n && Double.isFinite(n.doubleValue()) ? n : null;
    // Links the source skipped (deleted ones) still count toward progress.
    if (!Js.truthy(result.get("cursor")) && total != null) {
      stepDone = Math.max(stepDone, Js.toNumber(total));
    }
    return Json.object(
        "cursor", result.get("cursor"),
        "done", Js.num(stepDone),
        "total", total,
        "links", links,
        "clicks", clicks,
        "skipped", skipped,
        "failed", failed);
  }
}
