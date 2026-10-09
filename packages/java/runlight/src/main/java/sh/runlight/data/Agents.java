package sh.runlight.data;

import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import sh.runlight.Json;

/**
 * AI agents, matched on the user agent, checked before the bot test so they are recorded as fetches
 * rather than dropped. An agent is an object with name, company, kind, and token.
 *
 * <p>"live" means an assistant fetched the page because a person asked about it just now. "crawl"
 * is training or search indexing. The token is matched case-insensitively as a substring of the
 * user agent.
 */
public final class Agents {
  private Agents() {}

  public static final List<Map<String, Object>> AI_AGENTS =
      List.of(
          agent("ChatGPT-User", "OpenAI", "live", "chatgpt-user"),
          agent("OAI-SearchBot", "OpenAI", "crawl", "oai-searchbot"),
          agent("GPTBot", "OpenAI", "crawl", "gptbot"),
          agent("Claude-User", "Anthropic", "live", "claude-user"),
          agent("Claude-SearchBot", "Anthropic", "crawl", "claude-searchbot"),
          agent("ClaudeBot", "Anthropic", "crawl", "claudebot"),
          agent("Claude-Web", "Anthropic", "crawl", "claude-web"),
          agent("anthropic-ai", "Anthropic", "crawl", "anthropic-ai"),
          agent("Perplexity-User", "Perplexity", "live", "perplexity-user"),
          agent("PerplexityBot", "Perplexity", "crawl", "perplexitybot"),
          agent("MistralAI-User", "Mistral", "live", "mistralai-user"),
          agent("meta-externalfetcher", "Meta", "live", "meta-externalfetcher"),
          agent("meta-externalagent", "Meta", "crawl", "meta-externalagent"),
          agent("DuckAssistBot", "DuckDuckGo", "crawl", "duckassistbot"),
          agent("Amazonbot", "Amazon", "crawl", "amazonbot"),
          agent("Bytespider", "ByteDance", "crawl", "bytespider"),
          agent("CCBot", "Common Crawl", "crawl", "ccbot"),
          agent("cohere-ai", "Cohere", "crawl", "cohere-ai"),
          agent("YouBot", "You.com", "crawl", "youbot"),
          agent("Diffbot", "Diffbot", "crawl", "diffbot"),
          agent("Timpibot", "Timpi", "crawl", "timpibot"));

  /** Anything that is clearly not a person in a browser. */
  public static final Pattern BOT_PATTERN =
      Pattern.compile(
          "bot\\b|bot/|crawl|spider|slurp|scrap|fetch|headless|lighthouse|pagespeed|gtmetrix|pingdom|uptime|monitor|preview|validator|python|curl/|wget|httpclient|okhttp|java/|go-http|axios|node-fetch|undici|libwww|phantomjs|selenium|puppeteer|playwright|facebookexternalhit|embedly|whatsapp|telegram|discord|slackbot|skypeuripreview|bitlybot|feed|rss|reader|archive\\.org|ia_archiver|semrush|ahrefs|mj12|dotbot|petalbot|bingpreview|yandex(?!browser)|baiduspider|sogou|exabot|seznam|qwant(?!ify)|applebot",
          Pattern.CASE_INSENSITIVE);

  private static Map<String, Object> agent(String name, String company, String kind, String token) {
    return Collections.unmodifiableMap(
        Json.object("name", name, "company", company, "kind", kind, "token", token));
  }
}
