//! AI agents, matched on the user agent, checked before the bot test so they
//! are recorded as fetches rather than dropped.
//!
//! "live" means an assistant fetched the page because a person asked about it
//! just now. "crawl" is training or search indexing.

/// An AI agent: its name, its company, whether it is live or a crawler, and
/// the token matched case-insensitively as a substring of the user agent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AiAgent {
    /// The agent's name, as reports show it.
    pub name: &'static str,
    /// Who runs it.
    pub company: &'static str,
    /// `"live"` or `"crawl"`.
    pub kind: &'static str,
    /// Matched case-insensitively as a substring of the user agent.
    pub token: &'static str,
}

const fn agent(name: &'static str, company: &'static str, kind: &'static str, token: &'static str) -> AiAgent {
    AiAgent { name, company, kind, token }
}

/// The known AI agents, in the SDK's order.
pub const AI_AGENTS: &[AiAgent] = &[
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
    agent("Timpibot", "Timpi", "crawl", "timpibot"),
];

/// Anything that is clearly not a person in a browser, as the SDK's
/// `BOT_PATTERN` without its two lookaheads (`yandex(?!browser)` and
/// `qwant(?!ify)`), which [`crate::ua::is_bot`] checks by hand. Matched on
/// bytes with ASCII case folding, as JavaScript's `/i` without `u` folds.
pub const BOT_PATTERN: &str = r"(?i-u)bot\b|bot/|crawl|spider|slurp|scrap|fetch|headless|lighthouse|pagespeed|gtmetrix|pingdom|uptime|monitor|preview|validator|python|curl/|wget|httpclient|okhttp|java/|go-http|axios|node-fetch|undici|libwww|phantomjs|selenium|puppeteer|playwright|facebookexternalhit|embedly|whatsapp|telegram|discord|slackbot|skypeuripreview|bitlybot|feed|rss|reader|archive\.org|ia_archiver|semrush|ahrefs|mj12|dotbot|petalbot|bingpreview|baiduspider|sogou|exabot|seznam|applebot";
