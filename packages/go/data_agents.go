package runlight

import (
	"regexp"
	"strings"
)

// AiAgent is an AI agent, matched on the user agent, checked before the bot
// test so it is recorded as a fetch rather than dropped.
//
// Kind "live" means an assistant fetched the page because a person asked
// about it just now. "crawl" is training or search indexing.
type AiAgent struct {
	Name    string `json:"name"`
	Company string `json:"company"`
	Kind    string `json:"kind"`
	// Token is matched case-insensitively as a substring of the user agent.
	Token string `json:"token"`
}

// AiAgents is every AI agent Runlight knows, in the order they are tried.
var AiAgents = []AiAgent{
	{"ChatGPT-User", "OpenAI", "live", "chatgpt-user"},
	{"OAI-SearchBot", "OpenAI", "crawl", "oai-searchbot"},
	{"GPTBot", "OpenAI", "crawl", "gptbot"},
	{"Claude-User", "Anthropic", "live", "claude-user"},
	{"Claude-SearchBot", "Anthropic", "crawl", "claude-searchbot"},
	{"ClaudeBot", "Anthropic", "crawl", "claudebot"},
	{"Claude-Web", "Anthropic", "crawl", "claude-web"},
	{"anthropic-ai", "Anthropic", "crawl", "anthropic-ai"},
	{"Perplexity-User", "Perplexity", "live", "perplexity-user"},
	{"PerplexityBot", "Perplexity", "crawl", "perplexitybot"},
	{"MistralAI-User", "Mistral", "live", "mistralai-user"},
	{"meta-externalfetcher", "Meta", "live", "meta-externalfetcher"},
	{"meta-externalagent", "Meta", "crawl", "meta-externalagent"},
	{"DuckAssistBot", "DuckDuckGo", "crawl", "duckassistbot"},
	{"Amazonbot", "Amazon", "crawl", "amazonbot"},
	{"Bytespider", "ByteDance", "crawl", "bytespider"},
	{"CCBot", "Common Crawl", "crawl", "ccbot"},
	{"cohere-ai", "Cohere", "crawl", "cohere-ai"},
	{"YouBot", "You.com", "crawl", "youbot"},
	{"Diffbot", "Diffbot", "crawl", "diffbot"},
	{"Timpibot", "Timpi", "crawl", "timpibot"},
}

// botPattern is the SDK's BOT_PATTERN without its two lookaheads,
// yandex(?!browser) and qwant(?!ify), which Go's regexp lacks; isBot tests
// those two by hand.
var botPattern = regexp.MustCompile(`bot\b|bot/|crawl|spider|slurp|scrap|fetch|headless|lighthouse|pagespeed|gtmetrix|pingdom|uptime|monitor|preview|validator|python|curl/|wget|httpclient|okhttp|java/|go-http|axios|node-fetch|undici|libwww|phantomjs|selenium|puppeteer|playwright|facebookexternalhit|embedly|whatsapp|telegram|discord|slackbot|skypeuripreview|bitlybot|feed|rss|reader|archive\.org|ia_archiver|semrush|ahrefs|mj12|dotbot|petalbot|bingpreview|baiduspider|sogou|exabot|seznam|applebot`)

// foldASCII lowercases ASCII letters only, as a JavaScript regex's /i
// flag without u compares them.
func foldASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

// lookahead reports whether word appears in text not followed by not.
func lookahead(text, word, not string) bool {
	for at := 0; ; {
		i := strings.Index(text[at:], word)
		if i < 0 {
			return false
		}
		end := at + i + len(word)
		if !strings.HasPrefix(text[end:], not) {
			return true
		}
		at = at + i + 1
	}
}

// matchesBotPattern is BOT_PATTERN.test(ua). The pattern is matched against
// the text with its ASCII letters lowercased, which is what the /i flag
// does for a pattern of ASCII letters.
func matchesBotPattern(ua string) bool {
	lower := foldASCII(ua)
	return botPattern.MatchString(lower) || lookahead(lower, "yandex", "browser") || lookahead(lower, "qwant", "ify")
}
