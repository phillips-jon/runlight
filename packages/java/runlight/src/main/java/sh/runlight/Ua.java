package sh.runlight;

import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.data.Agents;

/**
 * Browser, OS, and device from a user agent, plus the AI agent and bot tests.
 *
 * <p>A client is an object with browser, browserVersion, os, osVersion, and device (desktop,
 * mobile, or tablet). Client hints are the low entropy ones Chromium browsers send on every
 * request: an object with brands, mobile, and platform, each a string or absent.
 *
 * <p>The patterns keep JavaScript's meaning: {@code .} stops at any line terminator and \S at any
 * JavaScript white space, both spelled out.
 */
public final class Ua {
  private Ua() {}

  private record Browser(String name, Pattern pattern) {}

  private static final List<Browser> BROWSERS =
      List.of(
          new Browser("Edge", Pattern.compile("(?:Edg|EdgA|EdgiOS|Edge)/(\\d+)")),
          new Browser("Opera", Pattern.compile("(?:OPR|OPiOS|Opera)/(\\d+)")),
          new Browser("Samsung Internet", Pattern.compile("SamsungBrowser/(\\d+)")),
          new Browser("Yandex Browser", Pattern.compile("YaBrowser/(\\d+)")),
          new Browser("Vivaldi", Pattern.compile("Vivaldi/(\\d+)")),
          new Browser("UC Browser", Pattern.compile("UCBrowser/(\\d+)")),
          new Browser("DuckDuckGo", Pattern.compile("(?:Ddg|DuckDuckGo)/(\\d+)")),
          new Browser("Facebook", Pattern.compile("FB(?:AV|_IAB)/(\\d+)")),
          new Browser("Instagram", Pattern.compile("Instagram (\\d+)")),
          new Browser("Firefox", Pattern.compile("(?:Firefox|FxiOS)/(\\d+)")),
          new Browser("Chrome", Pattern.compile("(?:CriOS|Chrome)/(\\d+)")),
          new Browser(
              "Safari",
              Pattern.compile("Version/(\\d+)[\\d.]* (?:Mobile/[^" + Js.SPACE + "]+ )?Safari/")),
          new Browser(
              "Internet Explorer", Pattern.compile("(?:MSIE |Trident/" + Js.DOT + "*rv:)(\\d+)")));

  private static final Map<String, String> WINDOWS =
      Map.of("10.0", "10", "6.3", "8.1", "6.2", "8", "6.1", "7", "6.0", "Vista", "5.1", "XP");

  private static final Pattern MOZILLA = Pattern.compile("mozilla|opera", Pattern.CASE_INSENSITIVE);
  private static final Pattern WEBVIEW = Pattern.compile("; wv\\)");
  private static final Pattern WINDOWS_NT = Pattern.compile("Windows NT (\\d+\\.\\d+)");
  private static final Pattern IOS =
      Pattern.compile("(?:iPhone|iPad|iPod)" + Js.DOT + "*? OS (\\d+)");
  private static final Pattern ANDROID = Pattern.compile("Android (\\d+)");
  private static final Pattern TABLET = Pattern.compile("iPad|Tablet|PlayBook|Silk");
  private static final Pattern MOBILE = Pattern.compile("Mobi|iPhone|iPod|Opera Mini|IEMobile");

  /** The AI agent a user agent names, or null. */
  public static Map<String, Object> aiAgent(String ua) {
    String lower = Js.lower(ua);
    for (Map<String, Object> agent : Agents.AI_AGENTS) {
      if (lower.contains((String) agent.get("token"))) {
        return agent;
      }
    }
    return null;
  }

  public static boolean isBot(String ua) {
    if (ua.length() < 20 || !MOZILLA.matcher(ua).find()) {
      return true;
    }
    return Agents.BOT_PATTERN.matcher(ua).find();
  }

  private static String unquote(Object value) {
    return Js.trim((value instanceof String s ? s : "").replace("\"", ""));
  }

  public static Map<String, Object> parseClient(String ua) {
    return parseClient(ua, Map.of(), null);
  }

  /**
   * The browser, OS, and device.
   *
   * @param hints the client hints, an object with brands, mobile, and platform
   * @param screenWidth the screen's width, or null when not sent
   */
  public static Map<String, Object> parseClient(
      String ua, Map<String, Object> hints, Double screenWidth) {
    if (hints == null) {
      hints = Map.of();
    }
    String browser = "Other";
    String browserVersion = "";
    for (Browser b : BROWSERS) {
      Matcher match = b.pattern().matcher(ua);
      if (match.find()) {
        browser = b.name();
        browserVersion = match.group(1) == null ? "" : match.group(1);
        break;
      }
    }
    if (browser.equals("Chrome") && WEBVIEW.matcher(ua).find()) {
      browser = "Android WebView";
    }
    // Brave looks like Chrome in the user agent but names itself in the hints.
    if (browser.equals("Chrome") && Js.strOr(hints.get("brands"), "").contains("\"Brave\"")) {
      browser = "Brave";
    }

    String os = "Other";
    String osVersion = "";
    Matcher match;
    if ((match = WINDOWS_NT.matcher(ua)).find()) {
      os = "Windows";
      osVersion = WINDOWS.getOrDefault(match.group(1), "");
    } else if ((match = IOS.matcher(ua)).find()) {
      os = "iOS";
      osVersion = match.group(1);
    } else if ((match = ANDROID.matcher(ua)).find()) {
      os = "Android";
      osVersion = match.group(1);
    } else if (ua.contains("Android")) {
      os = "Android";
    } else if (ua.contains("CrOS")) {
      os = "Chrome OS";
    } else if (ua.contains("Mac OS X") || ua.contains("Macintosh")) {
      // macOS froze its version in the user agent at 10.15, so it says nothing.
      os = "macOS";
    } else if (ua.contains("Linux") || ua.contains("X11")) {
      os = "Linux";
    }
    String platform = unquote(hints.get("platform"));
    if (os.equals("Other") && !platform.isEmpty()) {
      os = platform.equals("macOS") ? "macOS" : platform;
    }

    String device = "desktop";
    if (TABLET.matcher(ua).find() || (os.equals("Android") && !ua.contains("Mobile"))) {
      device = "tablet";
    } else if (MOBILE.matcher(ua).find() || unquote(hints.get("mobile")).equals("?1")) {
      device = "mobile";
    } else if (os.equals("macOS")
        && screenWidth != null
        && List.of(768.0, 810.0, 820.0, 834.0, 1024.0).contains(screenWidth)) {
      // iPadOS asks for desktop sites with a Mac user agent; the screen gives it away.
      device = "tablet";
      os = "iOS";
    }
    return Json.object(
        "browser", browser,
        "browserVersion", browserVersion,
        "os", os,
        "osVersion", osVersion,
        "device", device);
  }
}
