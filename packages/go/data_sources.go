package runlight

import "regexp"

// KnownSource is a known traffic source. Hosts match a referrer host or any
// subdomain of it; Aliases match a lowercased utm_source, ref, or source
// parameter. Kept as data so every implementation reads the same list.
type KnownSource struct {
	Name string `json:"name"`
	// Kind is search, social, ai, email, or other.
	Kind    string   `json:"kind"`
	Hosts   []string `json:"hosts"`
	Aliases []string `json:"aliases,omitempty"`
}

// Sources is every known traffic source.
var Sources = []KnownSource{
	// AI assistants
	{"ChatGPT", "ai", []string{"chatgpt.com", "chat.openai.com", "openai.com"}, []string{"chatgpt", "chatgpt.com", "openai"}},
	{"Claude", "ai", []string{"claude.ai"}, []string{"claude", "claude.ai", "anthropic"}},
	{"Perplexity", "ai", []string{"perplexity.ai"}, []string{"perplexity", "perplexity.ai"}},
	{"Gemini", "ai", []string{"gemini.google.com", "bard.google.com"}, []string{"gemini", "gemini.google.com", "bard"}},
	{"Copilot", "ai", []string{"copilot.microsoft.com", "copilot.cloud.microsoft"}, []string{"copilot", "copilot.microsoft.com"}},
	{"Meta AI", "ai", []string{"meta.ai"}, []string{"meta.ai", "metaai"}},
	{"Grok", "ai", []string{"grok.com", "x.ai"}, []string{"grok", "grok.com"}},
	{"DeepSeek", "ai", []string{"chat.deepseek.com", "deepseek.com"}, []string{"deepseek"}},
	{"Mistral", "ai", []string{"chat.mistral.ai", "mistral.ai"}, []string{"mistral", "lechat"}},
	{"You.com", "ai", []string{"you.com"}, []string{"you.com"}},
	{"Phind", "ai", []string{"phind.com"}, []string{"phind"}},

	// Search
	{"Google", "search", []string{"com.google.android.googlequicksearchbox", "google.com", "google.co.uk", "google.ca", "google.com.au", "google.de", "google.fr", "google.es", "google.it", "google.nl", "google.co.in", "google.co.jp", "google.com.br", "google.com.mx", "google.ie", "google.co.nz", "google.ch", "google.at", "google.be", "google.se", "google.dk", "google.no", "google.fi", "google.pl", "google.pt"}, []string{"google"}},
	{"Bing", "search", []string{"bing.com"}, []string{"bing"}},
	{"DuckDuckGo", "search", []string{"duckduckgo.com"}, []string{"duckduckgo", "ddg"}},
	{"Yahoo", "search", []string{"yahoo.com", "search.yahoo.com"}, []string{"yahoo"}},
	{"Yandex", "search", []string{"yandex.ru", "yandex.com"}, []string{"yandex"}},
	{"Baidu", "search", []string{"baidu.com"}, []string{"baidu"}},
	{"Ecosia", "search", []string{"ecosia.org"}, []string{"ecosia"}},
	{"Brave Search", "search", []string{"search.brave.com"}, []string{"brave"}},
	{"Startpage", "search", []string{"startpage.com"}, []string{"startpage"}},
	{"Qwant", "search", []string{"qwant.com"}, []string{"qwant"}},
	{"Kagi", "search", []string{"kagi.com"}, []string{"kagi"}},
	{"Naver", "search", []string{"naver.com"}, []string{"naver"}},

	// Social
	{"Facebook", "social", []string{"facebook.com", "fb.com", "m.facebook.com", "l.facebook.com", "lm.facebook.com"}, []string{"facebook", "fb"}},
	{"Instagram", "social", []string{"instagram.com", "l.instagram.com"}, []string{"instagram", "ig"}},
	{"X", "social", []string{"x.com", "twitter.com", "t.co"}, []string{"twitter", "x", "x.com"}},
	{"LinkedIn", "social", []string{"linkedin.com", "lnkd.in", "com.linkedin.android"}, []string{"linkedin"}},
	{"Reddit", "social", []string{"reddit.com", "old.reddit.com", "out.reddit.com", "com.reddit.frontpage"}, []string{"reddit"}},
	{"Hacker News", "social", []string{"news.ycombinator.com"}, []string{"hackernews", "hn", "news.ycombinator.com"}},
	{"YouTube", "social", []string{"youtube.com", "youtu.be", "m.youtube.com"}, []string{"youtube", "yt"}},
	{"Pinterest", "social", []string{"pinterest.com", "pin.it"}, []string{"pinterest"}},
	{"TikTok", "social", []string{"tiktok.com"}, []string{"tiktok"}},
	{"Threads", "social", []string{"threads.net", "threads.com"}, []string{"threads"}},
	{"Bluesky", "social", []string{"bsky.app"}, []string{"bluesky", "bsky"}},
	{"Mastodon", "social", []string{"mastodon.social", "mastodon.online", "fosstodon.org", "hachyderm.io"}, []string{"mastodon"}},
	{"Product Hunt", "social", []string{"producthunt.com"}, []string{"producthunt"}},
	{"GitHub", "social", []string{"github.com"}, []string{"github"}},
	{"Dev.to", "social", []string{"dev.to"}, []string{"devto", "dev.to"}},
	{"Medium", "social", []string{"medium.com"}, []string{"medium"}},
	{"Substack", "social", []string{"substack.com"}, []string{"substack"}},
	{"Discord", "social", []string{"discord.com", "discordapp.com"}, []string{"discord"}},
	{"Slack", "social", []string{"slack.com", "com.slack"}, []string{"slack"}},
	{"Telegram", "social", []string{"t.me", "telegram.org"}, []string{"telegram"}},
	{"WhatsApp", "social", []string{"whatsapp.com", "wa.me"}, []string{"whatsapp"}},

	// Email
	{"Gmail", "email", []string{"mail.google.com", "com.google.android.gm"}, []string{"gmail"}},
	{"Kit", "email", []string{"kit.com", "convertkit.com", "ck.page", "kit-mail.com"}, []string{"kit", "convertkit"}},
	{"Outlook", "email", []string{"outlook.live.com", "outlook.office.com", "outlook.office365.com"}, []string{"outlook"}},
	{"Yahoo Mail", "email", []string{"mail.yahoo.com"}, []string{"yahoomail"}},
	{"Fastmail", "email", []string{"app.fastmail.com", "fastmail.com"}, []string{"fastmail"}},
	{"Proton Mail", "email", []string{"mail.proton.me"}, []string{"protonmail"}},
	{"Newsletter", "email", []string{}, []string{"newsletter", "email", "e-mail", "mailchimp", "kit", "convertkit", "beehiiv", "buttondown"}},
}

// sourcePatterns are hosts known by their shape rather than their name:
// email services' click trackers (Kit sends clicks through numbered hosts
// like 15a992bb.click.convertkit-mail4.com) and webmail (mail.aol.com,
// mail01.orange.fr, webmail.example.net). An empty name is the host itself.
var sourcePatterns = []struct {
	pattern *regexp.Regexp
	name    string
	kind    string
}{
	{regexp.MustCompile(`(^|\.)convertkit-mail\d*\.com$|(^|\.)kit-mail\d*\.com$`), "Kit", "email"},
	{regexp.MustCompile(`(^|\.)(list-manage|mailchi)\.(com|mp)$`), "Mailchimp", "email"},
	{regexp.MustCompile(`(^|\.)beehiiv\.com$`), "beehiiv", "email"},
	{regexp.MustCompile(`(^|\.)substack\.com$`), "Substack", "email"},
	{regexp.MustCompile(`^(web)?mail\d*\.|(^|\.)webmail\.`), "", "email"},
}
