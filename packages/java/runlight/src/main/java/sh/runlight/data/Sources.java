package sh.runlight.data;

import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import sh.runlight.Json;

/**
 * Known traffic sources. {@code hosts} match a referrer host or any subdomain of it; {@code
 * aliases} match a lowercased utm_source, ref or source parameter. Kept as data so every
 * implementation reads the same list. A source is an object with name, kind (search, social, ai,
 * email, or other), hosts, and aliases when it has them.
 */
public final class Sources {
  private Sources() {}

  public static final List<Map<String, Object>> SOURCES =
      List.of(
          source(
              "ChatGPT",
              "ai",
              List.of("chatgpt.com", "chat.openai.com", "openai.com"),
              List.of("chatgpt", "chatgpt.com", "openai")),
          source("Claude", "ai", List.of("claude.ai"), List.of("claude", "claude.ai", "anthropic")),
          source(
              "Perplexity", "ai", List.of("perplexity.ai"), List.of("perplexity", "perplexity.ai")),
          source(
              "Gemini",
              "ai",
              List.of("gemini.google.com", "bard.google.com"),
              List.of("gemini", "gemini.google.com", "bard")),
          source(
              "Copilot",
              "ai",
              List.of("copilot.microsoft.com", "copilot.cloud.microsoft"),
              List.of("copilot", "copilot.microsoft.com")),
          source("Meta AI", "ai", List.of("meta.ai"), List.of("meta.ai", "metaai")),
          source("Grok", "ai", List.of("grok.com", "x.ai"), List.of("grok", "grok.com")),
          source(
              "DeepSeek", "ai", List.of("chat.deepseek.com", "deepseek.com"), List.of("deepseek")),
          source(
              "Mistral",
              "ai",
              List.of("chat.mistral.ai", "mistral.ai"),
              List.of("mistral", "lechat")),
          source("You.com", "ai", List.of("you.com"), List.of("you.com")),
          source("Phind", "ai", List.of("phind.com"), List.of("phind")),
          source(
              "Google",
              "search",
              List.of(
                  "com.google.android.googlequicksearchbox",
                  "google.com",
                  "google.co.uk",
                  "google.ca",
                  "google.com.au",
                  "google.de",
                  "google.fr",
                  "google.es",
                  "google.it",
                  "google.nl",
                  "google.co.in",
                  "google.co.jp",
                  "google.com.br",
                  "google.com.mx",
                  "google.ie",
                  "google.co.nz",
                  "google.ch",
                  "google.at",
                  "google.be",
                  "google.se",
                  "google.dk",
                  "google.no",
                  "google.fi",
                  "google.pl",
                  "google.pt"),
              List.of("google")),
          source("Bing", "search", List.of("bing.com"), List.of("bing")),
          source("DuckDuckGo", "search", List.of("duckduckgo.com"), List.of("duckduckgo", "ddg")),
          source("Yahoo", "search", List.of("yahoo.com", "search.yahoo.com"), List.of("yahoo")),
          source("Yandex", "search", List.of("yandex.ru", "yandex.com"), List.of("yandex")),
          source("Baidu", "search", List.of("baidu.com"), List.of("baidu")),
          source("Ecosia", "search", List.of("ecosia.org"), List.of("ecosia")),
          source("Brave Search", "search", List.of("search.brave.com"), List.of("brave")),
          source("Startpage", "search", List.of("startpage.com"), List.of("startpage")),
          source("Qwant", "search", List.of("qwant.com"), List.of("qwant")),
          source("Kagi", "search", List.of("kagi.com"), List.of("kagi")),
          source("Naver", "search", List.of("naver.com"), List.of("naver")),
          source(
              "Facebook",
              "social",
              List.of(
                  "facebook.com", "fb.com", "m.facebook.com", "l.facebook.com", "lm.facebook.com"),
              List.of("facebook", "fb")),
          source(
              "Instagram",
              "social",
              List.of("instagram.com", "l.instagram.com"),
              List.of("instagram", "ig")),
          source(
              "X",
              "social",
              List.of("x.com", "twitter.com", "t.co"),
              List.of("twitter", "x", "x.com")),
          source(
              "LinkedIn",
              "social",
              List.of("linkedin.com", "lnkd.in", "com.linkedin.android"),
              List.of("linkedin")),
          source(
              "Reddit",
              "social",
              List.of("reddit.com", "old.reddit.com", "out.reddit.com", "com.reddit.frontpage"),
              List.of("reddit")),
          source(
              "Hacker News",
              "social",
              List.of("news.ycombinator.com"),
              List.of("hackernews", "hn", "news.ycombinator.com")),
          source(
              "YouTube",
              "social",
              List.of("youtube.com", "youtu.be", "m.youtube.com"),
              List.of("youtube", "yt")),
          source("Pinterest", "social", List.of("pinterest.com", "pin.it"), List.of("pinterest")),
          source("TikTok", "social", List.of("tiktok.com"), List.of("tiktok")),
          source("Threads", "social", List.of("threads.net", "threads.com"), List.of("threads")),
          source("Bluesky", "social", List.of("bsky.app"), List.of("bluesky", "bsky")),
          source(
              "Mastodon",
              "social",
              List.of("mastodon.social", "mastodon.online", "fosstodon.org", "hachyderm.io"),
              List.of("mastodon")),
          source("Product Hunt", "social", List.of("producthunt.com"), List.of("producthunt")),
          source("GitHub", "social", List.of("github.com"), List.of("github")),
          source("Dev.to", "social", List.of("dev.to"), List.of("devto", "dev.to")),
          source("Medium", "social", List.of("medium.com"), List.of("medium")),
          source("Substack", "social", List.of("substack.com"), List.of("substack")),
          source("Discord", "social", List.of("discord.com", "discordapp.com"), List.of("discord")),
          source("Slack", "social", List.of("slack.com", "com.slack"), List.of("slack")),
          source("Telegram", "social", List.of("t.me", "telegram.org"), List.of("telegram")),
          source("WhatsApp", "social", List.of("whatsapp.com", "wa.me"), List.of("whatsapp")),
          source(
              "Gmail",
              "email",
              List.of("mail.google.com", "com.google.android.gm"),
              List.of("gmail")),
          source(
              "Kit",
              "email",
              List.of("kit.com", "convertkit.com", "ck.page", "kit-mail.com"),
              List.of("kit", "convertkit")),
          source(
              "Outlook",
              "email",
              List.of("outlook.live.com", "outlook.office.com", "outlook.office365.com"),
              List.of("outlook")),
          source("Yahoo Mail", "email", List.of("mail.yahoo.com"), List.of("yahoomail")),
          source(
              "Fastmail",
              "email",
              List.of("app.fastmail.com", "fastmail.com"),
              List.of("fastmail")),
          source("Proton Mail", "email", List.of("mail.proton.me"), List.of("protonmail")),
          source(
              "Newsletter",
              "email",
              List.of(),
              List.of(
                  "newsletter",
                  "email",
                  "e-mail",
                  "mailchimp",
                  "kit",
                  "convertkit",
                  "beehiiv",
                  "buttondown")));

  /**
   * A host known by its shape, with the name to give it (null for the host itself) and its kind.
   */
  public record SourcePattern(Pattern pattern, String name, String kind) {}

  /**
   * Hosts known by their shape rather than their name: email services' click trackers (Kit sends
   * clicks through numbered hosts like 15a992bb.click.convertkit-mail4.com) and webmail
   * (mail.aol.com, mail01.orange.fr, webmail.example.net).
   */
  public static final List<SourcePattern> SOURCE_PATTERNS =
      List.of(
          new SourcePattern(
              Pattern.compile("(^|\\.)convertkit-mail\\d*\\.com\\z|(^|\\.)kit-mail\\d*\\.com\\z"),
              "Kit",
              "email"),
          new SourcePattern(
              Pattern.compile("(^|\\.)(list-manage|mailchi)\\.(com|mp)\\z"), "Mailchimp", "email"),
          new SourcePattern(Pattern.compile("(^|\\.)beehiiv\\.com\\z"), "beehiiv", "email"),
          new SourcePattern(Pattern.compile("(^|\\.)substack\\.com\\z"), "Substack", "email"),
          new SourcePattern(
              Pattern.compile("^(web)?mail\\d*\\.|(^|\\.)webmail\\."), null, "email"));

  private static Map<String, Object> source(
      String name, String kind, List<String> hosts, List<String> aliases) {
    Map<String, Object> source = Json.object("name", name, "kind", kind, "hosts", hosts);
    if (aliases != null) {
      source.put("aliases", aliases);
    }
    return java.util.Collections.unmodifiableMap(source);
  }
}
