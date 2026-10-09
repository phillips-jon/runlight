//! Known traffic sources. `hosts` match a referrer host or any subdomain of
//! it; `aliases` match a lowercased utm_source, ref or source parameter.
//! Kept as data so every implementation reads the same list.

/// What kind of place a source is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceKind {
    /// A search engine.
    Search,
    /// A social network or community.
    Social,
    /// An AI assistant.
    Ai,
    /// An email service or newsletter.
    Email,
    /// Anything else.
    Other,
}

/// A known source.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KnownSource {
    /// The name it is shown under.
    pub name: &'static str,
    /// What kind of place it is.
    pub kind: SourceKind,
    /// Hosts that are it, and their subdomains.
    pub hosts: &'static [&'static str],
    /// Lowercased utm_source, ref, or source values that name it.
    pub aliases: &'static [&'static str],
}

/// The known sources, in the SDK's order.
pub const SOURCES: &[KnownSource] = &[
    // AI assistants
    KnownSource {
        name: "ChatGPT",
        kind: SourceKind::Ai,
        hosts: &["chatgpt.com", "chat.openai.com", "openai.com"],
        aliases: &["chatgpt", "chatgpt.com", "openai"],
    },
    KnownSource {
        name: "Claude",
        kind: SourceKind::Ai,
        hosts: &["claude.ai"],
        aliases: &["claude", "claude.ai", "anthropic"],
    },
    KnownSource {
        name: "Perplexity",
        kind: SourceKind::Ai,
        hosts: &["perplexity.ai"],
        aliases: &["perplexity", "perplexity.ai"],
    },
    KnownSource {
        name: "Gemini",
        kind: SourceKind::Ai,
        hosts: &["gemini.google.com", "bard.google.com"],
        aliases: &["gemini", "gemini.google.com", "bard"],
    },
    KnownSource {
        name: "Copilot",
        kind: SourceKind::Ai,
        hosts: &["copilot.microsoft.com", "copilot.cloud.microsoft"],
        aliases: &["copilot", "copilot.microsoft.com"],
    },
    KnownSource { name: "Meta AI", kind: SourceKind::Ai, hosts: &["meta.ai"], aliases: &["meta.ai", "metaai"] },
    KnownSource { name: "Grok", kind: SourceKind::Ai, hosts: &["grok.com", "x.ai"], aliases: &["grok", "grok.com"] },
    KnownSource {
        name: "DeepSeek",
        kind: SourceKind::Ai,
        hosts: &["chat.deepseek.com", "deepseek.com"],
        aliases: &["deepseek"],
    },
    KnownSource {
        name: "Mistral",
        kind: SourceKind::Ai,
        hosts: &["chat.mistral.ai", "mistral.ai"],
        aliases: &["mistral", "lechat"],
    },
    KnownSource { name: "You.com", kind: SourceKind::Ai, hosts: &["you.com"], aliases: &["you.com"] },
    KnownSource { name: "Phind", kind: SourceKind::Ai, hosts: &["phind.com"], aliases: &["phind"] },
    // Search
    KnownSource {
        name: "Google",
        kind: SourceKind::Search,
        hosts: &[
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
            "google.pt",
        ],
        aliases: &["google"],
    },
    KnownSource { name: "Bing", kind: SourceKind::Search, hosts: &["bing.com"], aliases: &["bing"] },
    KnownSource {
        name: "DuckDuckGo",
        kind: SourceKind::Search,
        hosts: &["duckduckgo.com"],
        aliases: &["duckduckgo", "ddg"],
    },
    KnownSource {
        name: "Yahoo",
        kind: SourceKind::Search,
        hosts: &["yahoo.com", "search.yahoo.com"],
        aliases: &["yahoo"],
    },
    KnownSource { name: "Yandex", kind: SourceKind::Search, hosts: &["yandex.ru", "yandex.com"], aliases: &["yandex"] },
    KnownSource { name: "Baidu", kind: SourceKind::Search, hosts: &["baidu.com"], aliases: &["baidu"] },
    KnownSource { name: "Ecosia", kind: SourceKind::Search, hosts: &["ecosia.org"], aliases: &["ecosia"] },
    KnownSource { name: "Brave Search", kind: SourceKind::Search, hosts: &["search.brave.com"], aliases: &["brave"] },
    KnownSource { name: "Startpage", kind: SourceKind::Search, hosts: &["startpage.com"], aliases: &["startpage"] },
    KnownSource { name: "Qwant", kind: SourceKind::Search, hosts: &["qwant.com"], aliases: &["qwant"] },
    KnownSource { name: "Kagi", kind: SourceKind::Search, hosts: &["kagi.com"], aliases: &["kagi"] },
    KnownSource { name: "Naver", kind: SourceKind::Search, hosts: &["naver.com"], aliases: &["naver"] },
    // Social
    KnownSource {
        name: "Facebook",
        kind: SourceKind::Social,
        hosts: &["facebook.com", "fb.com", "m.facebook.com", "l.facebook.com", "lm.facebook.com"],
        aliases: &["facebook", "fb"],
    },
    KnownSource {
        name: "Instagram",
        kind: SourceKind::Social,
        hosts: &["instagram.com", "l.instagram.com"],
        aliases: &["instagram", "ig"],
    },
    KnownSource {
        name: "X",
        kind: SourceKind::Social,
        hosts: &["x.com", "twitter.com", "t.co"],
        aliases: &["twitter", "x", "x.com"],
    },
    KnownSource {
        name: "LinkedIn",
        kind: SourceKind::Social,
        hosts: &["linkedin.com", "lnkd.in", "com.linkedin.android"],
        aliases: &["linkedin"],
    },
    KnownSource {
        name: "Reddit",
        kind: SourceKind::Social,
        hosts: &["reddit.com", "old.reddit.com", "out.reddit.com", "com.reddit.frontpage"],
        aliases: &["reddit"],
    },
    KnownSource {
        name: "Hacker News",
        kind: SourceKind::Social,
        hosts: &["news.ycombinator.com"],
        aliases: &["hackernews", "hn", "news.ycombinator.com"],
    },
    KnownSource {
        name: "YouTube",
        kind: SourceKind::Social,
        hosts: &["youtube.com", "youtu.be", "m.youtube.com"],
        aliases: &["youtube", "yt"],
    },
    KnownSource {
        name: "Pinterest",
        kind: SourceKind::Social,
        hosts: &["pinterest.com", "pin.it"],
        aliases: &["pinterest"],
    },
    KnownSource { name: "TikTok", kind: SourceKind::Social, hosts: &["tiktok.com"], aliases: &["tiktok"] },
    KnownSource {
        name: "Threads",
        kind: SourceKind::Social,
        hosts: &["threads.net", "threads.com"],
        aliases: &["threads"],
    },
    KnownSource { name: "Bluesky", kind: SourceKind::Social, hosts: &["bsky.app"], aliases: &["bluesky", "bsky"] },
    KnownSource {
        name: "Mastodon",
        kind: SourceKind::Social,
        hosts: &["mastodon.social", "mastodon.online", "fosstodon.org", "hachyderm.io"],
        aliases: &["mastodon"],
    },
    KnownSource {
        name: "Product Hunt",
        kind: SourceKind::Social,
        hosts: &["producthunt.com"],
        aliases: &["producthunt"],
    },
    KnownSource { name: "GitHub", kind: SourceKind::Social, hosts: &["github.com"], aliases: &["github"] },
    KnownSource { name: "Dev.to", kind: SourceKind::Social, hosts: &["dev.to"], aliases: &["devto", "dev.to"] },
    KnownSource { name: "Medium", kind: SourceKind::Social, hosts: &["medium.com"], aliases: &["medium"] },
    KnownSource { name: "Substack", kind: SourceKind::Social, hosts: &["substack.com"], aliases: &["substack"] },
    KnownSource {
        name: "Discord",
        kind: SourceKind::Social,
        hosts: &["discord.com", "discordapp.com"],
        aliases: &["discord"],
    },
    KnownSource { name: "Slack", kind: SourceKind::Social, hosts: &["slack.com", "com.slack"], aliases: &["slack"] },
    KnownSource {
        name: "Telegram",
        kind: SourceKind::Social,
        hosts: &["t.me", "telegram.org"],
        aliases: &["telegram"],
    },
    KnownSource {
        name: "WhatsApp",
        kind: SourceKind::Social,
        hosts: &["whatsapp.com", "wa.me"],
        aliases: &["whatsapp"],
    },
    // Email
    KnownSource {
        name: "Gmail",
        kind: SourceKind::Email,
        hosts: &["mail.google.com", "com.google.android.gm"],
        aliases: &["gmail"],
    },
    KnownSource {
        name: "Kit",
        kind: SourceKind::Email,
        hosts: &["kit.com", "convertkit.com", "ck.page", "kit-mail.com"],
        aliases: &["kit", "convertkit"],
    },
    KnownSource {
        name: "Outlook",
        kind: SourceKind::Email,
        hosts: &["outlook.live.com", "outlook.office.com", "outlook.office365.com"],
        aliases: &["outlook"],
    },
    KnownSource { name: "Yahoo Mail", kind: SourceKind::Email, hosts: &["mail.yahoo.com"], aliases: &["yahoomail"] },
    KnownSource {
        name: "Fastmail",
        kind: SourceKind::Email,
        hosts: &["app.fastmail.com", "fastmail.com"],
        aliases: &["fastmail"],
    },
    KnownSource { name: "Proton Mail", kind: SourceKind::Email, hosts: &["mail.proton.me"], aliases: &["protonmail"] },
    KnownSource {
        name: "Newsletter",
        kind: SourceKind::Email,
        hosts: &[],
        aliases: &["newsletter", "email", "e-mail", "mailchimp", "kit", "convertkit", "beehiiv", "buttondown"],
    },
];

/// Hosts known by their shape rather than their name: email services' click
/// trackers (Kit sends clicks through numbered hosts like
/// 15a992bb.click.convertkit-mail4.com) and webmail (mail.aol.com,
/// mail01.orange.fr, webmail.example.net). The patterns are JavaScript's,
/// each `$` the end of the text.
pub const SOURCE_PATTERNS: &[(&str, Option<&str>, SourceKind)] = &[
    (r"(^|\.)convertkit-mail[0-9]*\.com$|(^|\.)kit-mail[0-9]*\.com$", Some("Kit"), SourceKind::Email),
    (r"(^|\.)(list-manage|mailchi)\.(com|mp)$", Some("Mailchimp"), SourceKind::Email),
    (r"(^|\.)beehiiv\.com$", Some("beehiiv"), SourceKind::Email),
    (r"(^|\.)substack\.com$", Some("Substack"), SourceKind::Email),
    (r"^(web)?mail[0-9]*\.|(^|\.)webmail\.", None, SourceKind::Email),
];
