package sh.runlight;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import sh.runlight.http.Url;
import sh.runlight.store.SqlStore;

/**
 * Email reports: the period each one covers, and the message itself, in the reader's language.
 *
 * <p>A ReportPeriod is a map: {@code key} (w:&lt;monday&gt; or m:&lt;yyyy-mm&gt;, so each period is
 * sent once), {@code fromDate}, {@code toDate}, {@code previousFrom}, {@code previousTo}, and
 * {@code dueAt} (reports go out from 8am the day after the period ends, in the site's timezone).
 */
public final class Reports {
  private Reports() {}

  /** The last complete week (Monday to Sunday) or month before {@code now}, in a timezone. */
  public static Map<String, Object> lastPeriod(String frequency, long now, String timezone) {
    String today = Time.localDate(now, timezone);
    if (frequency.equals("monthly")) {
      String first = today.substring(0, 8) + "01";
      String fromDate = Time.addMonths(first, -1);
      return Json.object(
          "key", "m:" + fromDate.substring(0, 7),
          "fromDate", fromDate,
          "toDate", Time.addDays(first, -1),
          "previousFrom", Time.addMonths(fromDate, -1),
          "previousTo", Time.addDays(fromDate, -1),
          "dueAt", Time.startOf(first, timezone, 8));
    }
    int weekday = LocalDate.parse(today).getDayOfWeek().getValue() - 1;
    String monday = Time.addDays(today, -weekday);
    String fromDate = Time.addDays(monday, -7);
    return Json.object(
        "key", "w:" + fromDate,
        "fromDate", fromDate,
        "toDate", Time.addDays(monday, -1),
        "previousFrom", Time.addDays(fromDate, -7),
        "previousTo", Time.addDays(fromDate, -1),
        "dueAt", Time.startOf(monday, timezone, 8));
  }

  private static String esc(String value) {
    StringBuilder out = new StringBuilder(value.length());
    for (int i = 0; i < value.length(); i++) {
      char c = value.charAt(i);
      switch (c) {
        case '&' -> out.append("&amp;");
        case '<' -> out.append("&lt;");
        case '>' -> out.append("&gt;");
        case '"' -> out.append("&quot;");
        case '\'' -> out.append("&#39;");
        default -> out.append(c);
      }
    }
    return out.toString();
  }

  private static String duration(Number ms) {
    long seconds = (long) Js.round(ms.doubleValue() / 1000);
    if (seconds < 60) {
      return seconds + "s";
    }
    long minutes = Math.floorDiv(seconds, 60);
    if (minutes < 60) {
      return minutes + "m " + pad2(seconds % 60) + "s";
    }
    return Math.floorDiv(minutes, 60) + "h " + pad2(minutes % 60) + "m";
  }

  private static String pad2(long n) {
    String s = Long.toString(n);
    return s.length() < 2 ? "0" + s : s;
  }

  private static double d(Object value) {
    return ((Number) value).doubleValue();
  }

  private record Metric(String key, Function<Number, String> format, boolean lowerIsBetter) {}

  private record Delta(String text, String color, String tone) {}

  private record Listing(String title, List<String[]> rows) {}

  /**
   * One site's report for a period, in a language. {@code links} are absolute: the dashboard and
   * the recipient's unsubscribe page.
   *
   * @param store the Runlight's store
   * @param site a SiteRow: id, name, hostnames, and timezone
   * @param frequency "weekly" or "monthly"
   * @param period a ReportPeriod
   * @param links {@code dashboard} and {@code unsubscribe}
   * @return a BuiltReport: {@code subject}, {@code html}, and {@code text}
   */
  public static Map<String, Object> buildReport(
      SqlStore store,
      Map<String, Object> site,
      String frequency,
      Map<String, Object> period,
      String lang,
      Map<String, Object> links) {
    Messages.Translator words = Messages.translator(lang);
    String code = words.lang();
    String tz = (String) site.get("timezone");
    String siteId = (String) site.get("id");
    String siteName = (String) site.get("name");
    Map<String, Object> query =
        range(siteId, (String) period.get("fromDate"), (String) period.get("toDate"), tz);
    Map<String, Object> before =
        range(siteId, (String) period.get("previousFrom"), (String) period.get("previousTo"), tz);
    Map<String, Object> now = store.stats(query);
    Map<String, Object> prev = store.stats(before);
    List<Map<String, Object>> pages = store.breakdown(query, "page", 5, 0);
    List<Map<String, Object>> sources = store.breakdown(query, "source", 5, 0);
    List<Map<String, Object>> countries = store.breakdown(query, "country", 5, 0);
    List<Map<String, Object>> goals = store.goals(siteId);
    Map<String, Map<String, Object>> totals = store.goalTotalsAll(query, goals);

    Function<Number, String> number = n -> Intl.number(code, n);
    Function<Number, String> percent = n -> Intl.percent(code, n);
    Function<Number, String> decimal = n -> Intl.number(code, n, 1, 1);
    Function<String, String> monthName = day -> Intl.monthYear(code, day);
    String dashboard = (String) links.get("dashboard");
    String unsubscribe = (String) links.get("unsubscribe");

    boolean monthly = frequency.equals("monthly");
    String fromDate = (String) period.get("fromDate");
    String when =
        monthly
            ? words.t("email.when.month", Map.of("month", monthName.apply(fromDate)))
            : words.t("email.when.week");
    String against =
        monthly
            ? monthName.apply((String) period.get("previousFrom"))
            : words.t("email.before.week");
    Number visitors = (Number) now.get("visitors");
    Number prevVisitors = (Number) prev.get("visitors");
    String who = words.tn("headline.who", visitors, Map.of("n", number.apply(visitors)));
    String verb = words.tn("headline.visited", visitors);
    Double change =
        Js.truthy(prevVisitors) ? (d(visitors) - d(prevVisitors)) / d(prevVisitors) : null;
    String headline;
    if (d(prevVisitors) == 0 && d(visitors) > 0) {
      headline =
          words.t(
              "headline.fromNone",
              Map.of("who", who, "verb", verb, "when", when, "against", against));
    } else if (change == null) {
      headline = words.t("headline.plain", Map.of("who", who, "verb", verb, "when", when));
    } else {
      String key =
          Math.abs(change) < 0.005 ? "headline.same" : change > 0 ? "headline.up" : "headline.down";
      String changeText =
          words.t(
              change > 0 ? "headline.more" : "headline.fewer",
              Map.of("pct", Js.num(Math.abs(Js.round(change * 100)))));
      headline =
          words.t(
              key,
              Map.of(
                  "who",
                  who,
                  "verb",
                  verb,
                  "when",
                  when,
                  "against",
                  against,
                  "change",
                  changeText));
    }
    String subject =
        words.t(
            monthly ? "email.subject.month" : "email.subject.week",
            Map.of("site", siteName, "who", who, "month", monthName.apply(fromDate)));
    String dates = span(words, code, fromDate, (String) period.get("toDate"));

    List<Metric> metrics =
        List.of(
            new Metric("visitors", number, false),
            new Metric("visits", number, false),
            new Metric("pageviews", number, false),
            new Metric("viewsPerVisit", decimal, false),
            new Metric("bounceRate", percent, true),
            new Metric("visitDuration", Reports::duration, false));
    Function<Metric, Delta> delta =
        m -> {
          Object b = prev.get(m.key());
          if (!Js.truthy(b)) {
            return new Delta("", "#6b7280", "flat");
          }
          double c = (d(now.get(m.key())) - d(b)) / d(b);
          if (Math.abs(c) < 0.005) {
            return new Delta("0%", "#6b7280", "flat");
          }
          boolean good = m.lowerIsBetter() ? c < 0 : c > 0;
          return new Delta(
              (c > 0 ? "↑" : "↓") + " " + percent.apply(Math.abs(c)),
              good ? "#15803d" : "#b91c1c",
              good ? "up" : "down");
        };

    List<Listing> lists = new ArrayList<>();
    List<String[]> pageRows = new ArrayList<>();
    for (Map<String, Object> r : pages) {
      pageRows.add(
          new String[] {
            Js.truthy(r.get("value")) ? Js.string(r.get("value")) : "/",
            number.apply((Number) r.get("visitors"))
          });
    }
    lists.add(new Listing(words.t("email.pages"), pageRows));
    List<String[]> sourceRows = new ArrayList<>();
    for (Map<String, Object> r : sources) {
      sourceRows.add(
          new String[] {
            Js.truthy(r.get("value")) ? Js.string(r.get("value")) : words.t("goals.unknown"),
            number.apply((Number) r.get("visitors"))
          });
    }
    lists.add(new Listing(words.t("email.sources"), sourceRows));
    List<String[]> countryRows = new ArrayList<>();
    for (Map<String, Object> r : countries) {
      countryRows.add(
          new String[] {
            Intl.region(code, Js.string(r.get("value"))), number.apply((Number) r.get("visitors"))
          });
    }
    lists.add(new Listing(words.t("email.countries"), countryRows));
    if (!goals.isEmpty()) {
      List<Map<String, Object>> sorted = new ArrayList<>(goals);
      sorted.sort(
          (a, b) ->
              Double.compare(
                  d(totals.get((String) b.get("id")).get("conversions")),
                  d(totals.get((String) a.get("id")).get("conversions"))));
      List<String[]> goalRows = new ArrayList<>();
      for (Map<String, Object> goal : sorted) {
        Map<String, Object> t = totals.get((String) goal.get("id"));
        Number revenue = (Number) t.get("revenue");
        String name = (String) goal.get("name");
        goalRows.add(
            new String[] {
              !"none".equals(goal.get("valueMode")) && Js.truthy(revenue)
                  ? name
                      + " ("
                      + Intl.currency(
                          code,
                          revenue,
                          (String) goal.get("currency"),
                          Js.isInteger(revenue) ? 0 : 2)
                      + ")"
                  : name,
              number.apply((Number) t.get("conversions"))
            });
      }
      lists.add(new Listing(words.t("email.conversions"), goalRows));
    }

    String font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif";
    Function<Metric, String> cell =
        m -> {
          Delta dl = delta.apply(m);
          return "<td width=\"33%\" class=\"rl-line\" style=\"padding:12px 14px;border:1px solid"
              + " #e5e7eb;border-radius:10px;vertical-align:top\">\n"
              + "<div class=\"rl-muted\" style=\"font-size:11px;letter-spacing:.04em;"
              + "text-transform:uppercase;color:#6b7280\">"
              + esc(words.t("metric." + m.key()))
              + "</div>\n"
              + "<div class=\"rl-ink\" style=\"font-size:24px;font-weight:600;color:#111827;"
              + "margin-top:4px\">"
              + esc(m.format().apply((Number) now.get(m.key())))
              + "</div>\n"
              + "<div class=\"rl-"
              + dl.tone()
              + "\" style=\"font-size:12px;color:"
              + dl.color()
              + ";margin-top:2px;min-height:16px\">"
              + esc(dl.text())
              + "</div></td>";
        };
    Function<Listing, String> table =
        l -> {
          StringBuilder rows = new StringBuilder();
          if (!l.rows().isEmpty()) {
            for (String[] r : l.rows()) {
              rows.append(
                      "<tr><td class=\"rl-row rl-body-text\" style=\"padding:7px 0;border-top:1px"
                          + " solid #f0f0f0;color:#374151;word-break:break-all\">")
                  .append(esc(r[0]))
                  .append(
                      "</td><td align=\"right\" class=\"rl-row rl-ink\" style=\"padding:7px 0 7px"
                          + " 12px;border-top:1px solid #f0f0f0;color:#111827;font-weight:600;"
                          + "white-space:nowrap\">")
                  .append(esc(r[1]))
                  .append("</td></tr>");
            }
          } else {
            rows.append("<tr><td class=\"rl-muted\" style=\"padding:7px 0;color:#6b7280\">")
                .append(esc(words.t("panel.empty")))
                .append("</td></tr>");
          }
          return "<h3 class=\"rl-ink\" style=\"font-size:14px;color:#111827;margin:28px 0 8px\">"
              + esc(l.title())
              + "</h3>\n"
              + "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\""
              + " style=\"border-collapse:collapse;font-size:14px\">"
              + rows
              + "</table>";
        };

    // Where the dashboard lives, without the scheme or the site query, so a reader
    // with several installs can tell which one sent this.
    Url u = Url.parse(dashboard);
    String where =
        u != null
            ? u.host() + (u.pathname.endsWith("/") ? Js.slice(u.pathname, 0, -1) : u.pathname)
            : dashboard;
    String at = words.t("email.at", Map.of("where", where));
    // The Runlight mark in table cells: mail apps block SVG and most inline images.
    String mark =
        "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\""
            + " style=\"border-collapse:collapse\"><tr>\n"
            + "<td class=\"rl-mark\" width=\"24\" height=\"24\" align=\"center\""
            + " style=\"width:24px;height:24px;background:#111827;border-radius:7px;color:#ffffff;"
            + "font-size:15px;font-weight:700;line-height:24px;text-align:center;font-family:"
            + font
            + "\">R</td>\n"
            + "<td class=\"rl-ink\" style=\"padding-left:8px;font-size:15px;font-weight:700;"
            + "color:#111827;font-family:"
            + font
            + "\">Runlight</td></tr></table>";

    String footer =
        words.t(
            "email.footer",
            Map.of(
                "frequency",
                words.t(monthly ? "email.monthly" : "email.weekly"),
                "site",
                siteName));
    String atLine = esc(words.t("email.at", Map.of("where", "\u0000")));
    int hole = atLine.indexOf('\u0000');
    if (hole >= 0) {
      atLine =
          atLine.substring(0, hole)
              + "<a href=\""
              + esc(dashboard)
              + "\" class=\"rl-muted\" style=\"color:#6b7280\">"
              + esc(where)
              + "</a>"
              + atLine.substring(hole + 1);
    }
    StringBuilder cells1 = new StringBuilder();
    StringBuilder cells2 = new StringBuilder();
    for (int i = 0; i < metrics.size(); i++) {
      (i < 3 ? cells1 : cells2).append(cell.apply(metrics.get(i)));
    }
    StringBuilder tables = new StringBuilder();
    for (Listing l : lists) {
      tables.append(table.apply(l));
    }
    String html =
        "<!doctype html><html lang=\""
            + code
            + "\"><head><meta charset=\"utf-8\"><meta name=\"viewport\""
            + " content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\""
            + " content=\"light dark\"><meta name=\"supported-color-schemes\" content=\"light"
            + " dark\"><title>"
            + esc(subject)
            + "</title>\n"
            + "<style>\n"
            + "@media (prefers-color-scheme: dark) {\n"
            + "  .rl-page { background: #09090b !important; }\n"
            + "  .rl-card { background: #141417 !important; border-color: #27272a !important; }\n"
            + "  .rl-line { border-color: #27272a !important; }\n"
            + "  .rl-row { border-top-color: #1f1f23 !important; }\n"
            + "  .rl-ink { color: #ffffff !important; }\n"
            + "  .rl-body-text { color: #d4d4d8 !important; }\n"
            + "  .rl-muted, .rl-flat { color: #a1a1aa !important; }\n"
            + "  .rl-up { color: #4ade80 !important; }\n"
            + "  .rl-down { color: #f87171 !important; }\n"
            + "  .rl-button { background: #ffffff !important; color: #000000 !important; }\n"
            + "  .rl-mark { background: #ffffff !important; color: #000000 !important; }\n"
            + "  .rl-foot, .rl-foot a { color: #a1a1aa !important; }\n"
            + "}\n"
            + "</style></head>\n"
            + "<body class=\"rl-page\" style=\"margin:0;padding:0;background:#f4f4f5;font-family:"
            + font
            + "\">\n"
            + "<div style=\"display:none;max-height:0;overflow:hidden\">"
            + esc(headline)
            + "</div>\n"
            + "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\""
            + " class=\"rl-page\" style=\"background:#f4f4f5\"><tr><td align=\"center\""
            + " style=\"padding:32px 16px\">\n"
            + "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\""
            + " class=\"rl-card\" style=\"max-width:600px;background:#ffffff;border-radius:14px;"
            + "border:1px solid #e5e7eb\"><tr><td style=\"padding:32px\">\n"
            + "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\""
            + " style=\"border-collapse:collapse;margin:0 0 24px\"><tr>\n"
            + "<td style=\"vertical-align:middle\">"
            + mark
            + "</td>\n"
            + "<td align=\"right\" class=\"rl-muted\" style=\"vertical-align:middle;font-size:12px;"
            + "color:#6b7280\">"
            + atLine
            + "</td>\n"
            + "</tr></table>\n"
            + "<div class=\"rl-muted\" style=\"font-size:12px;letter-spacing:.04em;"
            + "text-transform:uppercase;color:#6b7280\">"
            + esc(siteName)
            + " · "
            + esc(dates)
            + "</div>\n"
            + "<h1 class=\"rl-ink\" style=\"font-size:24px;line-height:1.3;color:#111827;"
            + "margin:10px 0 24px;font-weight:600\">"
            + esc(headline)
            + "</h1>\n"
            + "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"6\""
            + " style=\"border-collapse:separate;margin:0 -6px\">\n"
            + "<tr>"
            + cells1
            + "</tr><tr>"
            + cells2
            + "</tr></table>\n"
            + tables
            + "\n"
            + "<p style=\"margin:32px 0 0\"><a href=\""
            + esc(dashboard)
            + "\" class=\"rl-button\" style=\"display:inline-block;background:#111827;"
            + "color:#ffffff;text-decoration:none;padding:11px 18px;border-radius:8px;"
            + "font-size:14px;font-weight:600\">"
            + esc(words.t("email.open"))
            + "</a></p>\n"
            + "</td></tr></table>\n"
            + "<p class=\"rl-foot\" style=\"max-width:600px;font-size:12px;line-height:1.5;"
            + "color:#6b7280;margin:16px auto 0\">"
            + esc(footer)
            + " <a href=\""
            + esc(unsubscribe)
            + "\" style=\"color:#6b7280\">"
            + esc(words.t("email.unsubscribe"))
            + "</a></p>\n"
            + "</td></tr></table></body></html>";

    // French sets a space before a colon, as its subject line does.
    String colon = code.equals("fr") ? " :" : ":";
    List<String> lines = new ArrayList<>();
    lines.add("Runlight · " + at);
    lines.add("");
    lines.add(siteName + " · " + dates);
    lines.add("");
    lines.add(headline);
    lines.add("");
    for (Metric m : metrics) {
      String dl = delta.apply(m).text();
      lines.add(
          words.t("metric." + m.key())
              + colon
              + " "
              + m.format().apply((Number) now.get(m.key()))
              + (dl.isEmpty() ? "" : " (" + dl + ")"));
    }
    for (Listing l : lists) {
      lines.add("");
      lines.add(l.title());
      if (!l.rows().isEmpty()) {
        for (String[] r : l.rows()) {
          lines.add("  " + r[0] + colon + " " + r[1]);
        }
      } else {
        lines.add("  " + words.t("panel.empty"));
      }
    }
    lines.add("");
    lines.add(words.t("email.open") + colon + " " + dashboard);
    lines.add("");
    lines.add(footer + " " + words.t("email.unsubscribe") + colon + " " + unsubscribe);

    Map<String, Object> out = new LinkedHashMap<>();
    out.put("subject", subject);
    out.put("html", html);
    out.put("text", String.join("\n", lines));
    return out;
  }

  private static Map<String, Object> range(String site, String from, String to, String tz) {
    return Json.object(
        "site",
        site,
        "from",
        Time.startOf(from, tz),
        "to",
        Time.startOf(Time.addDays(to, 1), tz),
        "filters",
        new ArrayList<>());
  }

  /** Each end formatted on its own, joined in the reader's language (never with a dash). */
  private static String span(Messages.Translator words, String code, String from, String to) {
    boolean sameYear = from.substring(0, 4).equals(to.substring(0, 4));
    return words.t(
        "email.range",
        Map.of("from", Intl.shortDay(code, from, !sameYear), "to", Intl.shortDay(code, to, true)));
  }
}
