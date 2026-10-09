// Writes packages/php/tests/fixtures/*.json: what the TypeScript SDK's pure modules (ua, sources, query,
// payload, time, geo, zip, brand, and version) answer for a wide set of inputs, so the PHP port can replay
// them and must give the same answers. Run with: node --import tsx scripts/php-fixtures-core.mts
import { mkdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { Reader } from "mmdb-lib";
import { aiAgent, isBot, parseClient, type ClientHints } from "../packages/sdk/src/ua.js";
import { attribute, parsePage, readablePath, recordedPath, sourceForAlias, sourceForHost, stripWww } from "../packages/sdk/src/sources.js";
import { DIMENSIONS, EVENT_DIMENSIONS, MAX_FILTERS, SESSION_DIMENSIONS, isDimension, isEventDimension, isSessionDimension, parseFilter } from "../packages/sdk/src/query.js";
import { MAX_BODY, parsePayload } from "../packages/sdk/src/payload.js";
import { PERIODS, addDays, addMonths, buckets, compareRange, isDate, isTimezone, localDate, localWeekdayHour, resolveRange, startOf, type CompareMode } from "../packages/sdk/src/time.js";
import { locate, locationFromHeaders } from "../packages/sdk/src/geo.js";
import { csv, csvRow, zip } from "../packages/sdk/src/zip.js";
import { RUNLIGHT_ICON } from "../packages/sdk/src/brand.js";
import { API_VERSION, VERSION } from "../packages/sdk/src/version.js";
import { lookupFrom } from "../packages/server/src/geo.js";

const dir = new URL("../packages/php/tests/fixtures/", import.meta.url);
mkdirSync(dir, { recursive: true });

/** Lone surrogates become U+FFFD, as they do once the SDK writes text out as UTF-8 (and as PHP holds it). */
function wellFormed(value: unknown): unknown {
  if (typeof value === "string") return value.toWellFormed();
  if (typeof value === "bigint") return value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : value.toString();
  if (Array.isArray(value)) return value.map(wellFormed);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k.toWellFormed(), wellFormed(v)]));
  return value;
}

function write(name: string, description: string, data: Record<string, unknown>): void {
  const text = JSON.stringify(wellFormed({ description, ...data })) + "\n";
  writeFileSync(new URL(`${name}.json`, dir), text);
  console.log(`${name}.json: ${(text.length / 1024).toFixed(0)} KB`);
}

const sha = (text: string) => createHash("sha256").update(text).digest("hex");

// ---------------------------------------------------------------- user agents

const AGENTS = [
  // Desktop browsers
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.2792.65",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0",
  "Mozilla/5.0 (Windows NT 6.1; WOW64; Trident/7.0; rv:11.0) like Gecko",
  "Mozilla/5.0 (compatible; MSIE 10.0; Windows NT 6.2; Trident/6.0)",
  "Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 5.1; Trident/4.0)",
  "Mozilla/5.0 (Windows NT 6.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/49.0.2623.112 Safari/537.36",
  "Mozilla/5.0 (Windows NT 6.3; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Windows NT 11.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 OPR/114.0.0.0",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 YaBrowser/24.10.0.0 Safari/537.36",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Vivaldi/6.9.3447.54",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36 Edge/18.19045",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6.1 Safari/605.1.15",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.7; rv:131.0) Gecko/20100101 Firefox/131.0",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) DuckDuckGo/7 Safari/605.1.15",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0",
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
  "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0",
  "Mozilla/5.0 (X11; Fedora; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0",
  "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
  "Mozilla/5.0 (X11; FreeBSD amd64; rv:128.0) Gecko/20100101 Firefox/128.0",
  "Opera/9.80 (Windows NT 6.1; WOW64) Presto/2.12.388 Version/12.18",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/129.0.0.0 Safari/537.36",
  // Phones and tablets
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/129.0.6668.69 Mobile/15E148 Safari/604.1",
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/131.0 Mobile/15E148 Safari/605.1.15",
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) EdgiOS/129.0.2792.84 Version/18.0 Mobile/15E148 Safari/604.1",
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 350.0.0.0.0 (iPhone14,5; iOS 18_0; en_US)",
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/482.0.0.0;FBBV/1;FBDV/iPhone14,5]",
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 DuckDuckGo/7 Safari/604.1",
  "Mozilla/5.0 (iPhone; CPU iPhone OS 12_5_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) OPiOS/16.0.14 Mobile/15E148 Safari/9537.53",
  "Mozilla/5.0 (iPad; CPU OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1",
  "Mozilla/5.0 (iPad; CPU OS 12_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
  "Mozilla/5.0 (iPod touch; CPU iPhone OS 12_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1",
  "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36",
  "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36",
  "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/26.0 Chrome/122.0.0.0 Mobile Safari/537.36",
  "Mozilla/5.0 (Linux; Android 13; SM-X700) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Linux; Android 14; Pixel 7 Build/AP2A.240905.003; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/129.0.6668.81 Mobile Safari/537.36",
  "Mozilla/5.0 (Linux; Android 14; Pixel 7 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/129.0.6668.81 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/482.0.0.48.86;]",
  "Mozilla/5.0 (Linux; Android 14; Pixel 7 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/129.0.6668.81 Mobile Safari/537.36 Instagram 350.0.0.0 Android",
  "Mozilla/5.0 (Android 14; Mobile; rv:131.0) Gecko/131.0 Firefox/131.0",
  "Mozilla/5.0 (Android 14; Tablet; rv:131.0) Gecko/131.0 Firefox/131.0",
  "Mozilla/5.0 (Linux; U; Android 12; en-US; SM-A125F Build/SP1A) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/100.0.4896.58 UCBrowser/13.6.0.1315 Mobile Safari/537.36",
  "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36 OPR/85.0.0.0",
  "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36 EdgA/129.0.0.0",
  "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36 DuckDuckGo/5",
  "Mozilla/5.0 (Linux; Android; Kindle Fire) AppleWebKit/537.36 (KHTML, like Gecko) Silk/124.3.1 like Chrome/124.0.6367.219 Safari/537.36",
  "Mozilla/5.0 (PlayBook; U; RIM Tablet OS 2.1.0; en-US) AppleWebKit/536.2+ (KHTML, like Gecko) Version/7.2.1.0 Safari/536.2+",
  "Opera/9.80 (Android; Opera Mini/36.2.2254/119.132; U; id) Presto/2.12.423 Version/12.16",
  "Mozilla/5.0 (Windows Phone 10.0; Android 6.0.1; Microsoft; Lumia 950) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/52.0.2743.116 Mobile Safari/537.36 Edge/15.15063",
  "Mozilla/5.0 (compatible; MSIE 10.0; Windows Phone 8.0; Trident/6.0; IEMobile/10.0; ARM; Touch; NOKIA; Lumia 920)",
  "Mozilla/5.0 (Linux; Tizen 2.3) AppleWebKit/538.1 (KHTML, like Gecko)Version/2.3 TV Safari/538.1",
  "Mozilla/5.0 (Nintendo Switch; WifiWebAuthApplet) AppleWebKit/606.4 (KHTML, like Gecko) NF/6.0.1.15.4 NintendoBrowser/5.1.0.20393",
  "Mozilla/5.0 (PlayStation; PlayStation 5/2.26) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0 Safari/605.1.15",
  "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/4.0 Chrome/76.0.3809.146 TV Safari/537.36",
  // AI agents
  "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot",
  "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; GPTBot/1.2; +https://openai.com/gptbot",
  "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; OAI-SearchBot/1.0; +https://openai.com/searchbot)",
  "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)",
  "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-User/1.0; +Claude-User@anthropic.com)",
  "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-SearchBot/1.0; +https://www.anthropic.com)",
  "Mozilla/5.0 (compatible; Claude-Web/1.0; +http://www.anthropic.com/bot.html)",
  "anthropic-ai",
  "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot)",
  "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Perplexity-User/1.0; +https://perplexity.ai/perplexity-user)",
  "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; MistralAI-User/1.0; +https://docs.mistral.ai/robots)",
  "meta-externalagent/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/crawler)",
  "meta-externalfetcher/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/crawler)",
  "DuckAssistBot/1.2; (+http://duckduckgo.com/duckassistbot.html)",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/600.2.5 (KHTML, like Gecko) Version/8.0.2 Safari/600.2.5 (Amazonbot/0.1; +https://developer.amazon.com/support/amazonbot)",
  "Mozilla/5.0 (Linux; Android 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; Bytespider; spider-feedback@bytedance.com)",
  "CCBot/2.0 (https://commoncrawl.org/faq/)",
  "cohere-ai",
  "Mozilla/5.0 (compatible; YouBot/1.0; +http://www.you.com/)",
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/49.0.2623.75 Safari/537.36 Diffbot/0.1",
  "Mozilla/5.0 (compatible; TimpiBot/0.8; +http://www.timpi.io)",
  "Mozilla/5.0 (compatible; CLAUDEBOT/1.0)",
  "Mozilla/5.0 (compatible; Klaudebot is not it; Claude‐User)",
  // Bots
  "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
  "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
  "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
  "Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)",
  "Mozilla/5.0 (compatible; Baiduspider/2.0; +http://www.baidu.com/search/spider.html)",
  "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)",
  "Mozilla/5.0 (compatible; SemrushBot/7~bl; +http://www.semrush.com/bot.html)",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.1.1 Safari/605.1.15 (Applebot/0.1; +http://www.apple.com/go/applebot)",
  "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
  "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
  "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)",
  "TelegramBot (like TwitterBot)",
  "WhatsApp/2.23.20.0",
  "Twitterbot/1.0",
  "LinkedInBot/1.0 (compatible; Mozilla/5.0; Apache-HttpClient +http://www.linkedin.com)",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Chrome-Lighthouse",
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 PingdomPageSpeed/1.0 (pingbot/2.0; +http://www.pingdom.com/)",
  "Mozilla/5.0 (compatible; UptimeRobot/2.0; http://www.uptimerobot.com/)",
  "curl/8.7.1",
  "Wget/1.21.4",
  "python-requests/2.32.3",
  "Python-urllib/3.12",
  "Go-http-client/2.0",
  "axios/1.7.7",
  "node-fetch/1.0 (+https://github.com/bitinn/node-fetch)",
  "undici",
  "okhttp/4.12.0",
  "Java/17.0.2",
  "libwww-perl/6.72",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) PhantomJS/2.1.1 Safari/537.36",
  "Feedly/1.0 (+http://www.feedly.com/fetcher.html; 7 subscribers; like FeedFetcher-Google)",
  "Mozilla/5.0 (compatible; Feedbin feed-id:1 - 3 subscribers)",
  "NetNewsWire (RSS Reader; https://netnewswire.com/)",
  "Mozilla/5.0 (compatible; archive.org_bot +http://www.archive.org/details/archive.org_bot)",
  "ia_archiver (+http://www.alexa.com/site/help/webmasters; crawler@alexa.com)",
  "Mozilla/5.0 (compatible; MJ12bot/v1.4.8; http://mj12bot.com/)",
  "Mozilla/5.0 (compatible; DotBot/1.2; +https://opensiteexplorer.org/dotbot; help@moz.com)",
  "Mozilla/5.0 (Linux; Android 7.0;) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; PetalBot;+https://webmaster.petalsearch.com/site/petalbot)",
  "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/534+ (KHTML, like Gecko) BingPreview/1.0b",
  "Sogou web spider/4.0(+http://www.sogou.com/docs/help/webmasters.htm#07)",
  "Mozilla/5.0 (compatible; Exabot/3.0; +http://www.exabot.com/go/robot)",
  "Mozilla/5.0 (compatible; SeznamBot/4.0; +https://o-seznam.cz/napoveda/vyhledavani/en/seznambot-crawler/)",
  "Mozilla/5.0 (compatible; Qwantify/2.4w; +https://www.qwant.com/)/2.4w",
  "Mozilla/5.0 (compatible; Qwantbot/1.0_4193332; +https://help.qwant.com/bot/)",
  "Mozilla/5.0 (Windows NT 10.0) Selenium",
  "Mozilla/5.0 (X11; Linux x86_64) Puppeteer",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Playwright/1.48",
  "Mozilla/5.0 (compatible; Embedly/0.2; +http://support.embed.ly/)",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36 SkypeUriPreview Preview/0.5",
  "bitlybot/3.0 (+http://bit.ly/)",
  "W3C_Validator/1.3 http://validator.w3.org/services",
  "GTmetrix",
  "Mozilla/5.0 (Windows NT 10.0) my-monitor",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) robot",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) robots",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Robotics lab",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) bottle shop",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) abbot",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) bot_",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) boté",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) YandexBrowser",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) yandexsearch",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ſpider",
  // Short, odd, and empty
  "",
  "Mozilla",
  "Mozilla/5.0",
  "Mozilla/5.0 (X)1234567",
  "Mozilla/5.0 (X)12345678",
  "Mozilla/5.0 (éé)12345",
  "Mozilla/5.0 (\u{1F600}\u{1F600})1234",
  "Mozilla/5.0 (\u{1F600}\u{1F600})123",
  "MOZILLA/5.0 (WINDOWS NT 10.0) CHROME/129",
  "Opera",
  "opera/12.0 (windows nt 6.1) presto",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/abc Safari/537.36",
  "Mozilla/5.0 (Windows NT 99.9; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
  "Mozilla/5.0 (iPhone; CPU iPhone OS like Mac OS X) Version/18.0 Mobile/15E148 Safari/604.1",
  "Mozilla/5.0 (Macintosh) Version/17 Mobile/15E148 x Safari/605",
  "Mozilla/5.0 (Macintosh) Version/17 Mobile/15E148 x Safari/605",
  "Mozilla/5.0 (Macintosh) Version/17.1.2 Safari/605",
  "Mozilla/5.0 (Macintosh) Version/17.1.2  Safari/605",
  "Mozilla/5.0 (Windows NT 6.1; Trident/7.0;\r rv:11.0) like Gecko",
  "Mozilla/5.0 (Windows NT 6.1; Trident/7.0;  rv:11.0) like Gecko",
  "Mozilla/5.0 (iPhone;\n CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
  "Mozilla/5.0 (Linux; Android) Chrome/129.0.0.0 Mobile",
  "Mozilla/5.0 (Linux; Android 4.4.2; Nexus 7 Build/KOT49H) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/34.0.1847.114 Safari/537.36",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Tablet",
  "Mozilla/5.0 (BB10; Touch) AppleWebKit/537.10+ (KHTML, like Gecko) Version/10.0.9.2372 Mobile Safari/537.10+",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/",
  "Mozilla/5.0 (Windows NT 5.1; rv:52.0) Gecko/20100101 Firefox/52.0",
  "Mozilla/5.0 (Windows NT 10.0) Version/1.2.3.4 Mobile/abc Safari/1",
  "Mozilla/5.0 (Windows NT 10.0) Version/1.2.3.4 Mobile/abc  Safari/1",
];

const HINTS: Array<{ hints?: ClientHints; screenWidth?: number }> = [
  {},
  { hints: { brands: '"Brave";v="129", "Chromium";v="129", "Not=A?Brand";v="8"', mobile: "?0", platform: '"Windows"' } },
  { hints: { mobile: "?1", platform: '"Android"' } },
  { hints: { mobile: ' "?1" ' } },
  { hints: { platform: '"macOS"' } },
  { hints: { platform: '"Linux"' } },
  { hints: { platform: '" Chrome OS "' } },
  { hints: { platform: ' "Windows"　' } },
  { hints: { brands: null, mobile: null, platform: null } },
  { screenWidth: 768 },
  { screenWidth: 820 },
  { screenWidth: 1024 },
  { screenWidth: 1920 },
  { screenWidth: 0 },
];

const uaCases = [];
for (const ua of AGENTS) {
  for (const [i, variant] of HINTS.entries()) {
    // Every agent with no hints; the variants on a spread of them.
    if (i > 0 && AGENTS.indexOf(ua) % 3 !== i % 3) continue;
    uaCases.push({ ua, ...variant, agent: aiAgent(ua), bot: isBot(ua), client: parseClient(ua, variant.hints, variant.screenWidth) });
  }
}
write("ua", "User agents through aiAgent, isBot, and parseClient (with client hints and a screen width where given).", { cases: uaCases });

// ---------------------------------------------------------------- sources

const HOSTS = [
  "google.com", "www.google.com", "WWW.Google.COM", "google.co.uk", "www.google.co.uk", "news.google.com", "mail.google.com", "gemini.google.com",
  "bard.google.com", "www.gemini.google.com", "google.cn", "google", "", ".", "..", "com", "google.com.", ".google.com", "www.", "www.www.google.com",
  "chatgpt.com", "chat.openai.com", "openai.com", "platform.openai.com", "claude.ai", "www.perplexity.ai", "copilot.microsoft.com", "copilot.cloud.microsoft",
  "meta.ai", "grok.com", "x.ai", "x.com", "t.co", "twitter.com", "mobile.twitter.com", "facebook.com", "l.facebook.com", "lm.facebook.com", "m.facebook.com",
  "web.facebook.com", "instagram.com", "l.instagram.com", "linkedin.com", "lnkd.in", "com.linkedin.android", "reddit.com", "old.reddit.com", "out.reddit.com",
  "com.reddit.frontpage", "news.ycombinator.com", "ycombinator.com", "youtube.com", "m.youtube.com", "youtu.be", "pinterest.com", "pin.it", "tiktok.com",
  "threads.net", "threads.com", "bsky.app", "mastodon.social", "fosstodon.org", "hachyderm.io", "producthunt.com", "www.producthunt.com", "github.com",
  "gist.github.com", "dev.to", "medium.com", "someone.medium.com", "substack.com", "someone.substack.com", "discord.com", "discordapp.com", "slack.com",
  "app.slack.com", "com.slack", "t.me", "telegram.org", "whatsapp.com", "wa.me", "web.whatsapp.com", "com.google.android.gm", "com.google.android.googlequicksearchbox",
  "kit.com", "convertkit.com", "ck.page", "kit-mail.com", "kit-mail3.com", "15a992bb.click.convertkit-mail4.com", "convertkit-mail.com", "click.convertkit-mail2.com",
  "notconvertkit-mail.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "mail.yahoo.com", "app.fastmail.com", "fastmail.com",
  "mail.proton.me", "us12.list-manage.com", "mailchi.mp", "list-manage.mp", "mailchi.com", "x.mailchi.mp.evil.com", "newsletter.beehiiv.com", "beehiiv.com",
  "mail.aol.com", "mail01.orange.fr", "webmail.example.net", "web.mail.example.net", "webmail01.example.net", "mailbox.org", "mail.", "mail1.x", "email.example.com",
  "mail١.x", "bing.com", "www.bing.com", "cn.bing.com", "duckduckgo.com", "html.duckduckgo.com", "search.yahoo.com", "yahoo.com", "uk.search.yahoo.com",
  "yandex.ru", "yandex.com", "baidu.com", "ecosia.org", "search.brave.com", "brave.com", "startpage.com", "qwant.com", "kagi.com", "naver.com", "search.naver.com",
  "chat.deepseek.com", "deepseek.com", "chat.mistral.ai", "mistral.ai", "you.com", "phind.com", "example.com", "localhost", "127.0.0.1", "[::1]", "xn--bcher-kva.example",
  "BÜCHER.example", "İstanbul.example", "www.ſubstack.com",
];
const ALIASES = [
  "google", "Google", " GOOGLE ", "bing", "ddg", "chatgpt", "chatgpt.com", "www.chatgpt.com", "openai", "claude", "claude.ai", "anthropic", "perplexity", "gemini",
  "bard", "copilot", "metaai", "grok", "deepseek", "lechat", "you.com", "phind", "facebook", "fb", "ig", "twitter", "x", "x.com", "linkedin", "reddit", "hn",
  "hackernews", "news.ycombinator.com", "yt", "youtube", "producthunt", "github", "devto", "dev.to", "medium", "substack", "discord", "slack", "telegram",
  "whatsapp", "gmail", "kit", "convertkit", "outlook", "yahoomail", "fastmail", "protonmail", "newsletter", "email", "e-mail", "Email", "mailchimp", "beehiiv",
  "buttondown", "weekly", "partner", "", " ", "www.google.com", "google.com", "mail.google.com", "www.mail.google.com", " google ", "GOOGLE\t",
  "t.co", "unknown.example", "Kit", "İnstagram",
];
const PAGES = [
  "https://example.com/",
  "https://www.example.com/a/b?email=x@y.z&utm_campaign=spring&fbclid=123#top",
  "https://example.com/post?utm_source=chatgpt.com",
  "https://example.com/?utm_source=google&utm_medium=cpc",
  "https://example.com/?utm_source=google&utm_medium=CPC&utm_campaign=Brand",
  "https://example.com/?utm_source=weekly&utm_medium=email",
  "https://example.com/?utm_source=weekly&utm_medium=E-Mail",
  "https://example.com/?utm_source=newsletter",
  "https://example.com/?utm_source=partner&utm_campaign=launch",
  "https://example.com/?utm_medium=social",
  "https://example.com/?utm_medium=paid_social&utm_source=facebook",
  "https://example.com/?utm_term=shoes",
  "https://example.com/?utm_content=hero",
  "https://example.com/?ref=producthunt",
  "https://example.com/?source=github",
  "https://example.com/?ref=&source=reddit",
  "https://example.com/?gclid=abc",
  "https://example.com/?msclkid=abc&utm_source=bing",
  "https://example.com/?li_fat_id=1",
  "https://example.com/?ttclid",
  "https://example.com/?yclid=1&utm_medium=email",
  "https://example.com/café",
  "https://example.com/caf%C3%A9?x=1",
  "https://example.com/a%2Fb/%20c",
  "https://example.com/#",
  "https://example.com/#/route",
  "https://example.com/path#a b",
  "https://EXAMPLE.com/UPPER/Path",
  "https://www.example.com",
  "https://www.www.example.com/",
  "http://localhost:3000/x",
  "https://example.com/?utm_source=%20%20padded%20%20",
  "https://example.com/?utm_source=" + "s".repeat(250),
  "https://example.com/?utm_source=" + "\u{1F600}".repeat(120),
  "https://example.com/?utm_source=" + "a" + "\u{1F600}".repeat(110),
  "https://example.com/?utm_medium=%C4%B0MAIL",
  "https://example.com/?utm_medium=EMAIL%E2%80%A8",
  "https://example.com/?utm_source=%FF%FE",
  "https://example.com/?utm_source=a+b&utm_campaign=c%2Bd",
  "https://example.com/" + "p".repeat(1100),
  "https://example.com/" + "é".repeat(400),
  "https://example.com/" + "\u{1F600}".repeat(400) + "#hash",
  "https://example.com/?utm_source=chatgpt.com&utm_medium=cpc",
  "https://example.com/?utm_source=gmail&utm_medium=social",
  "https://example.com/?utm_medium=cpc",
  "https://example.com/?utm_medium=display&gclid=1",
  "https://example.com/?utm_source=Kit",
  "https://example.com/?utm_source=t.co",
  "https://xn--bcher-kva.example/",
  "https://bücher.example/",
  "https://example.com:8443/x",
  "https://192.168.0.1/",
];
const REFERRERS = [
  "", "https://www.google.co.uk/", "https://www.google.com/", "https://google.com/search?q=x", "https://chatgpt.com/", "https://chat.openai.com/c/1",
  "https://www.perplexity.ai/search/x", "https://claude.ai/", "https://news.ycombinator.com/item?id=1", "https://t.co/abc", "https://someblog.net/post",
  "https://www.example.com/a", "https://example.com/b", "https://shop.example.com/a", "not a url", "android-app://com.google.android.gm/",
  "android-app://com.google.android.googlequicksearchbox/https/www.google.com", "android-app://com.Slack", "android-app://", "https://com.google.android.gm/",
  "https://15a992bb.click.convertkit-mail4.com/x", "https://mail01.orange.fr/", "https://mail.aol.com/", "https://mailbox.org/", "ftp://example.org/",
  "file:///etc/passwd", "javascript:alert(1)", "https://l.facebook.com/l.php?u=x", "https://www.bing.com/search?q=x", "http://duckduckgo.com/",
  "https://user:pass@www.reddit.com/r/x", "https://example.org/" + "r".repeat(600), "https://example.org/" + "\u{1F600}".repeat(300), "https://example.org/café",
  "https://WWW.LinkedIn.com/feed", "https://lnkd.in/abc", "https://out.reddit.com/t3", "https://mail.google.com/mail/u/0/", "https://gemini.google.com/app",
  "https://us12.list-manage.com/track/click", "https://webmail.example.net/", "https://localhost:3000/", "https://[::1]/", "https://example.com:8443/",
  "  https://www.google.com/  ", "https://bücher.example/x", "HTTPS://WWW.GOOGLE.COM/", "https:google.com", "https://", "//google.com/",
];
const INTERNAL = [[], ["shop.example.com"], ["someblog.net", "google.com"]];

const pages: Array<{ url: string; page: unknown }> = [];
for (const url of PAGES) {
  let page: unknown = null;
  try {
    page = parsePage(new URL(url));
  } catch {
    page = null;
  }
  pages.push({ url, page });
}
const visits = [];
for (const [p, url] of PAGES.entries()) {
  for (const [r, referrer] of REFERRERS.entries()) {
    // Every referrer against the plain page; the rest of the grid thinned out.
    if (p !== 0 && (p + r) % 5 !== 0) continue;
    for (const [i, internal] of INTERNAL.entries()) {
      if (i > 0 && (p + r + i) % 3 !== 0) continue;
      visits.push({ url, referrer, internal, attribution: attribute(parsePage(new URL(url)), referrer, internal) });
    }
  }
}
const PATHS = [
  "", "/", "pricing", "/pricing", "/pricing?x=1", "/pricing#top", "pricing/", "https://example.com/pricing?x=1#a", "HTTPS://EXAMPLE.COM/A", "http://x.com",
  "https://example.com", "/café", "café", "/a b", "/a%20b", "/%7Euser", "/a/../b", "/a/./b/.", "//double", "///triple", "\\back\\slash", "/emoji/\u{1F600}",
  "/tab\there", " /lead", "/trail ", "https://", "https://exa mple.com/", "mailto:x@y.z", "javascript:alert(1)", "?only=query", "#only-hash", "/x#", "/x?#",
  "/" + "z".repeat(1200), "ftp://example.com/x", "https://example.com:99999/", "/a\"b<c>`d{e}", "/%zz", "/100%", "/%C3", "/\u0000",
  "https://www.example.com/a?b#c", "/ ",
];
const READABLE = [
  "/", "/caf%C3%A9", "/caf%c3%a9", "/a%2Fb", "/a%2fb", "/a%20b", "/a%3Fb", "/a%23b", "/a%25b", "/%E2%82%AC100", "/%F0%9F%98%80", "/%C3", "/%C3%A9%FF", "/%FF",
  "/%E2%80%A8", "/%C2%A0", "/%E2%80%8B", "/%EF%BB%BF", "/%00", "/%7F", "/%C2%80", "/%E0%A4%A", "/%ZZ", "/100%", "/%%41", "/%41%42%43", "/%C3%A9%2F%C3%A9",
  "/%ED%A0%80", "/%F4%90%80%80", "/%C0%AF", "/%E0%80%AF", "/%F0%9F%98", "/a%2Cb", "/%E2%80%AE", "/%E3%80%80", "/%EE%80%80", "/%F3%B0%80%80", "/%CD%B8",
  "/%F0%B1%8D%90", "/%DF%BF", "/é%C3%A9", "/%e2%82%ac/%E2%82%AC", "/%3A%40%21",
];
const STRIP = ["www.example.com", "WWW.EXAMPLE.COM", "example.com", "www.", "www", "wwww.example.com", "www.www.x", "İ.com", "Www.x"];

write("sources", "Referrer and channel attribution: sourceForHost, sourceForAlias, parsePage, attribute, recordedPath, readablePath, and stripWww.", {
  hosts: HOSTS.map((host) => ({ host, source: sourceForHost(host) })),
  aliases: ALIASES.map((alias) => ({ alias, source: sourceForAlias(alias) })),
  pages,
  visits,
  recordedPaths: PATHS.map((input) => ({ input, path: recordedPath(input) })),
  readablePaths: READABLE.map((input) => ({ input, path: readablePath(input) })),
  stripWww: STRIP.map((input) => ({ input, host: stripWww(input) })),
});

// ---------------------------------------------------------------- query

const FILTERS = [
  "page:is:/pricing", "page:not:/", "page:contains:a:b:c", "country:is:CA", "utm_source:is:", "event:is:Signup", "hostname:contains:example",
  "ai_agent:is:GPTBot", "ai_page:is:/", "nope:is:x", "page:equals:x", "page:is", "page", "", ":", "::", "page::x", ":is:x", "PAGE:is:x", "page:IS:x",
  "page:is:" + "v".repeat(600), "page:is:" + "\u{1F600}".repeat(260), "page:is:" + "a" + "\u{1F600}".repeat(260), "__proto__:is:x", "constructor:is:x",
  "toString:is:x", "browser_version:contains:12", "language:not:en-US", "page:is:café", "exit:is:/x", "entry:is:/y", "screen:is:1920x1080",
];
const DIM_TESTS = [...DIMENSIONS, "nope", "", "__proto__", "constructor", "hasOwnProperty", "Page", "ai_agent", "ai_page"];
write("query", "Report dimensions and filters: the dimension lists, MAX_FILTERS, the is*Dimension tests, and parseFilter.", {
  eventDimensions: EVENT_DIMENSIONS,
  sessionDimensions: SESSION_DIMENSIONS,
  dimensions: DIMENSIONS,
  maxFilters: MAX_FILTERS,
  dimensionTests: DIM_TESTS.map((value) => ({ value, isDimension: isDimension(value), isSessionDimension: isSessionDimension(value), isEventDimension: isEventDimension(value) })),
  filters: FILTERS.map((text) => ({ text, filter: parseFilter(text) })),
});

// ---------------------------------------------------------------- payload

const base = { k: "pageview", s: "site", u: "https://example.com/" };
const event = { k: "event", s: "site", u: "https://example.com/", n: "Signup" };
const BODIES: string[] = [
  JSON.stringify(base),
  JSON.stringify({ ...base, r: "https://google.com/", t: "Home", w: 1920, h: 1080, l: "en-US", d: 55 }),
  JSON.stringify({ ...base, w: 1919.5, h: -3, d: 100.49999999999999 }),
  JSON.stringify({ ...base, w: 0.49999999999999994, h: 2.5, d: -0.5 }),
  JSON.stringify({ ...base, w: -2.5, h: 20000.5, d: 101 }),
  JSON.stringify({ ...base, w: "1920", h: true, d: null }),
  '{"k":"pageview","u":"https://example.com/","w":1e400,"h":-1e400,"d":1e-400}',
  '{"k":"pageview","u":"https://example.com/","w":99999999999999999999,"h":-0,"d":-0.0}',
  '{"k":"pageview","u":"https://example.com/","w":12345678901234567890123,"h":9007199254740993}',
  JSON.stringify({ ...base, k: "nope" }),
  JSON.stringify({ ...base, k: "PAGEVIEW" }),
  JSON.stringify({ ...base, u: "ftp://example.com/" }),
  JSON.stringify({ ...base, u: "javascript:alert(1)" }),
  JSON.stringify({ ...base, u: "not a url" }),
  JSON.stringify({ ...base, u: 42 }),
  JSON.stringify({ ...base, u: "https://example.com/" + "x".repeat(2100) }),
  JSON.stringify({ ...base, u: "https://example.com/" + "\u{1F600}".repeat(1100) }),
  JSON.stringify({ ...base, u: "  https://Example.COM/a/../b?x=1#h  " }),
  JSON.stringify({ ...base, s: "s".repeat(80), r: "r".repeat(2100), t: "\u{1F600}".repeat(300), l: "en-US-x-" + "y".repeat(40) }),
  JSON.stringify({ ...base, t: "a" + "\u{1F600}".repeat(300) }),
  JSON.stringify(event),
  JSON.stringify({ ...event, n: "" }),
  JSON.stringify({ ...event, n: "   " }),
  JSON.stringify({ ...event, n: " Signup　" }),
  JSON.stringify({ ...event, n: "n".repeat(130) }),
  JSON.stringify({ ...event, n: 5 }),
  JSON.stringify({ ...event, p: { plan: "pro", seats: 5, price: 9.99, trial: true, nope: null, obj: {}, arr: [1] } }),
  JSON.stringify({ ...event, p: { b: "1", 2: "two", a: "3", 1: "one", "-1": "neg", "01": "lead", "4294967294": "max", "4294967295": "over" } }),
  JSON.stringify({ ...event, p: { b: "1", " 3": "x", "3 ": "y" } }),
  JSON.stringify({ ...event, p: { " a ": "1", a: "2", "": "3", "   ": "4" } }),
  JSON.stringify({ ...event, p: { ["k".repeat(70)]: "v".repeat(600) } }),
  JSON.stringify({ ...event, p: { ["\u{1F600}".repeat(40)]: "a" + "\u{1F600}".repeat(300) } }),
  JSON.stringify({ ...event, p: Object.fromEntries(Array.from({ length: 40 }, (_, i) => [`k${i}`, `v${i}`])) }),
  JSON.stringify({ ...event, p: Object.fromEntries(Array.from({ length: 40 }, (_, i) => [`k${i}`, i % 2 ? null : `v${i}`])) }),
  JSON.stringify({ ...event, p: { big: 1e21, small: 1e-7, neg: -0, frac: 0.1 + 0.2, huge: 12345678901234567890, exp: 1.5e300, third: 1 / 3 } }),
  '{"k":"event","u":"https://example.com/","n":"x","p":{"__proto__":"x"}}',
  '{"k":"event","u":"https://example.com/","n":"x","p":{"__proto__":"x","a":"1"}}',
  '{"k":"event","u":"https://example.com/","n":"x","p":{"a":"1","a":"2","b":"3"}}',
  '{"k":"event","u":"https://example.com/","n":"x","p":{"n":12345678901234567890,"m":9007199254740993,"o":-9007199254740993}}',
  JSON.stringify({ ...event, p: [] }),
  JSON.stringify({ ...event, p: ["a"] }),
  JSON.stringify({ ...event, p: "string" }),
  JSON.stringify({ ...event, p: {} }),
  JSON.stringify({ ...event, p: { a: null } }),
  JSON.stringify({ ...base, p: { a: "1" } }),
  JSON.stringify({ ...base, k: "engagement" }),
  JSON.stringify({ ...base, k: "engagement", i: "abc123", e: 5000, d: 40 }),
  JSON.stringify({ ...base, k: "engagement", i: "ABC123", e: 99999999 }),
  JSON.stringify({ ...base, k: "engagement", i: "abc", e: -5 }),
  JSON.stringify({ ...base, k: "engagement", i: "abc", e: "5" }),
  JSON.stringify({ ...base, i: "abc-123" }),
  JSON.stringify({ ...base, i: "a".repeat(40) }),
  JSON.stringify({ ...base, i: "K" }),
  JSON.stringify({ ...base, i: "abc\n" }),
  JSON.stringify({ ...base, i: 123 }),
  JSON.stringify({ ...base, x: "y".repeat(9000) }),
  JSON.stringify({ ...base, x: "y".repeat(8100) }),
  JSON.stringify({ ...base, x: "é".repeat(4060) }),
  JSON.stringify({ ...base, x: "é".repeat(4100) }),
  JSON.stringify({ ...base, x: "\u{1F600}".repeat(2040) }),
  JSON.stringify({ ...base, x: "\u{1F600}".repeat(2060) }),
  '{"k":"pageview","u":"https://example.com/","t":"\\ud800 lone"}',
  '{"k":"pageview","u":"https://example.com/","t":"\\udc00 low"}',
  '{"k":"pageview","u":"https://example.com/","t":"\\ud83d\\ude00 pair"}',
  '{"k":"pageview","u":"https://example.com/","t":"\\\\ud800 escaped backslash"}',
  '{"k":"event","u":"https://example.com/","n":"x","p":{"\\ud800":"\\udfff"}}',
  '{"k":"pageview","u":"https://example.com/","t":"' + "\\ud83d".repeat(1) + 'x"}',
  '{"k":"pageview","u":"https://example.com/","t":"' + "a".repeat(499) + '\\ud83d\\ude00"}',
  '{"k":"pageview","u":"https://example.com/","t":"tab\\there","l":"\\u0000"}',
  '{"k":"pageview","u":"https://example.com/","k":"event","n":"dup"}',
  ' \n {"k":"pageview","u":"https://example.com/"} \t ',
  '{"k":"pageview","u":"https://example.com/",}',
  "{'k':'pageview'}",
  "[]",
  "[{\"k\":\"pageview\"}]",
  "null",
  "true",
  "42",
  '"string"',
  "",
  "{",
  "﻿{\"k\":\"pageview\",\"u\":\"https://example.com/\"}",
  '{"k":"pageview","u":"https://example.com/","nested":' + "[".repeat(600) + "]".repeat(600) + "}",
  '{"k":"pageview","u":"https://example.com/","s":"été","r":"https://bücher.example/"}',
  '{"k":"pageview","u":"https://example.com/?utm_source=x#frag","s":"' + "s".repeat(63) + '\u{1F600}"}',
];
const payloads = BODIES.map((text) => {
  const p = parsePayload(text);
  return {
    text,
    payload: p && { ...p, url: p.url.href, props: p.props === null ? null : JSON.stringify(wellFormed(p.props)), screenWidth: p.screenWidth ?? null, screenHeight: p.screenHeight ?? null, scroll: p.scroll ?? null },
  };
});
write("payload", "Tracker bodies through parsePayload. url is the parsed URL's href, props is JSON.stringify of the props with any lone surrogate a cut left as U+FFFD (JSON.stringify itself would write it as an escape such as \\ud83d, which PHP strings cannot hold), and undefined numbers are null.", {
  maxBody: MAX_BODY,
  cases: payloads,
});

// ---------------------------------------------------------------- time

/** Names the time zone database keeps for compatibility (from PHP's list), which Intl may or may not take. */
const BACKWARD = [
  "Africa/Asmera", "Africa/Timbuktu", "America/Argentina/ComodRivadavia", "America/Atka", "America/Buenos_Aires", "America/Catamarca",
  "America/Coral_Harbour", "America/Cordoba", "America/Ensenada", "America/Fort_Wayne", "America/Godthab", "America/Indianapolis", "America/Jujuy",
  "America/Knox_IN", "America/Louisville", "America/Mendoza", "America/Montreal", "America/Nipigon", "America/Pangnirtung", "America/Porto_Acre",
  "America/Rainy_River", "America/Rosario", "America/Santa_Isabel", "America/Shiprock", "America/Thunder_Bay", "America/Virgin",
  "America/Yellowknife", "Antarctica/South_Pole", "Asia/Ashkhabad", "Asia/Calcutta", "Asia/Choibalsan", "Asia/Chongqing", "Asia/Chungking",
  "Asia/Dacca", "Asia/Harbin", "Asia/Istanbul", "Asia/Kashgar", "Asia/Katmandu", "Asia/Macao", "Asia/Rangoon", "Asia/Saigon", "Asia/Tel_Aviv",
  "Asia/Thimbu", "Asia/Ujung_Pandang", "Asia/Ulan_Bator", "Atlantic/Faeroe", "Atlantic/Jan_Mayen", "Australia/ACT", "Australia/Canberra",
  "Australia/Currie", "Australia/LHI", "Australia/North", "Australia/NSW", "Australia/Queensland", "Australia/South", "Australia/Tasmania",
  "Australia/Victoria", "Australia/West", "Australia/Yancowinna", "Brazil/Acre", "Brazil/DeNoronha", "Brazil/East", "Brazil/West", "Canada/Atlantic",
  "Canada/Central", "Canada/Eastern", "Canada/Mountain", "Canada/Newfoundland", "Canada/Pacific", "Canada/Saskatchewan", "Canada/Yukon", "CET",
  "Chile/Continental", "Chile/EasterIsland", "CST6CDT", "Cuba", "EET", "Egypt", "Eire", "EST", "EST5EDT", "Etc/GMT", "Etc/GMT+0", "Etc/GMT+1",
  "Etc/GMT+10", "Etc/GMT+11", "Etc/GMT+12", "Etc/GMT+2", "Etc/GMT+3", "Etc/GMT+4", "Etc/GMT+5", "Etc/GMT+6", "Etc/GMT+7", "Etc/GMT+8", "Etc/GMT+9",
  "Etc/GMT-0", "Etc/GMT-1", "Etc/GMT-10", "Etc/GMT-11", "Etc/GMT-12", "Etc/GMT-13", "Etc/GMT-14", "Etc/GMT-2", "Etc/GMT-3", "Etc/GMT-4", "Etc/GMT-5",
  "Etc/GMT-6", "Etc/GMT-7", "Etc/GMT-8", "Etc/GMT-9", "Etc/GMT0", "Etc/Greenwich", "Etc/UCT", "Etc/Universal", "Etc/UTC", "Etc/Zulu",
  "Europe/Belfast", "Europe/Kiev", "Europe/Nicosia", "Europe/Tiraspol", "Europe/Uzhgorod", "Europe/Zaporozhye", "Factory", "GB", "GB-Eire", "GMT",
  "GMT+0", "GMT-0", "GMT0", "Greenwich", "Hongkong", "HST", "Iceland", "Iran", "Israel", "Jamaica", "Japan", "Kwajalein", "Libya", "MET",
  "Mexico/BajaNorte", "Mexico/BajaSur", "Mexico/General", "MST", "MST7MDT", "Navajo", "NZ", "NZ-CHAT", "Pacific/Enderbury", "Pacific/Johnston",
  "Pacific/Ponape", "Pacific/Samoa", "Pacific/Truk", "Pacific/Yap", "Poland", "Portugal", "PRC", "PST8PDT", "ROC", "ROK", "Singapore", "Turkey",
  "UCT", "Universal", "US/Alaska", "US/Aleutian", "US/Arizona", "US/Central", "US/East-Indiana", "US/Eastern", "US/Hawaii", "US/Indiana-Starke",
  "US/Michigan", "US/Mountain", "US/Pacific", "US/Samoa", "W-SU", "WET", "Zulu",
];
const NAMES = [
  ...new Set([
    ...Intl.supportedValuesOf("timeZone"),
    ...BACKWARD,
    "Asia/Kolkata", "Europe/Kyiv", "America/Nuuk", "Pacific/Kanton", "Asia/Ho_Chi_Minh", "Asia/Kathmandu", "Asia/Yangon", "Atlantic/Faroe",
    "America/Ciudad_Juarez", "America/Coyhaique", "America/Argentina/Buenos_Aires", "America/Indiana/Indianapolis", "Asia/Dhaka", "Africa/Asmara",
    "ACT", "AET", "AGT", "ART", "AST", "BET", "BST", "CAT", "CNT", "CST", "CTT", "EAT", "ECT", "IET", "IST", "JST", "MIT", "NET", "NST", "PLT", "PNT", "PRT", "PST",
    "SST", "VST", "SystemV/AST4", "SystemV/AST4ADT", "SystemV/EST5", "SystemV/EST5EDT", "SystemV/CST6", "SystemV/CST6CDT", "SystemV/MST7", "SystemV/MST7MDT",
    "SystemV/PST8", "SystemV/PST8PDT", "SystemV/YST9", "SystemV/YST9YDT", "SystemV/HST10", "Canada/East-Saskatchewan", "US/Pacific-New",
    "america/toronto", "AMERICA/NEW_YORK", "EtC/uTc", "utc", "cet", "est", "pst", "systemv/est5edt", "Factory", "factory", "localtime", "posixrules", "Etc/Unknown",
    "Asia/Riyadh87", "Mideast/Riyadh87", "CEST", "EDT", "PDT", "IDT", "MSK", "AEST", "GMT+5", "GMT+05:00", "UTC+1", "Z", "z", "", " UTC", "UTC ", "Europe/London ",
    "+05:30", "+0530", "+05", "-00:00", "+00", "-12", "+1400", "+23:59", "-23:59", "+24:00", "+5:30", "+05:3", "+0", "+12:60", "+05:30:00", "−05:00", "−0530",
    "+05:30 ", "05:30", "Etc/GMT+13", "Etc/GMT-15", "America/Argentina/ComodRivadavia", "Europe/Belfast", "Asia/Hanoi", "Europe/Kyiv", "Europe/Kiev",
    "İstanbul", "Europe/İstanbul",
  ]),
];
const SAMPLE_TIMES = [
  Date.UTC(1900, 0, 1, 12), Date.UTC(1918, 6, 1), Date.UTC(1945, 6, 1), Date.UTC(1970, 0, 1), Date.UTC(1970, 6, 1), Date.UTC(1999, 11, 31, 23, 59, 59),
  Date.UTC(2000, 0, 15), Date.UTC(2011, 11, 30, 12), Date.UTC(2016, 1, 29, 12), Date.UTC(2024, 6, 1), Date.UTC(2026, 0, 15), Date.UTC(2026, 6, 15),
  Date.UTC(2026, 9, 6, 2), Date.UTC(2030, 2, 31, 1), Date.UTC(2038, 0, 19, 3, 14, 8), Date.UTC(2100, 6, 1),
];
const zones = NAMES.map((name) => {
  const valid = isTimezone(name);
  return { name, valid, local: valid ? SAMPLE_TIMES.map((ts) => `${localDate(ts, name)} ${localWeekdayHour(ts, name).join(" ")}`) : null };
});

const FOCUS = [
  "UTC", "America/Toronto", "Europe/London", "Australia/Lord_Howe", "Asia/Kolkata", "Asia/Kathmandu", "Pacific/Chatham", "Australia/Adelaide", "America/St_Johns",
  "Asia/Tehran", "America/Santiago", "America/Havana", "Atlantic/Azores", "America/Nuuk", "Asia/Gaza", "Pacific/Apia", "Pacific/Kiritimati", "Pacific/Pago_Pago",
  "Africa/Casablanca", "Europe/Dublin", "America/Sao_Paulo", "Asia/Tokyo", "America/Los_Angeles", "Etc/GMT-14", "Etc/GMT+12", "+05:30", "-03:30", "Antarctica/Troll",
  "Asia/Dhaka", "Europe/Moscow", "America/Caracas", "Australia/Eucla", "Asia/Pyongyang", "Pacific/Norfolk", "America/Scoresbysund",
];
const YEARS = [1900, 1916, 1970, 1996, 2007, 2011, 2016, 2024, 2026, 2027, 2038, 2050];

const offsetFormat = new Map<string, Intl.DateTimeFormat>();
/** Milliseconds a zone is ahead of UTC, read straight from Intl. */
function offsetOf(ts: number, zone: string): number {
  let f = offsetFormat.get(zone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone: zone, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" });
    offsetFormat.set(zone, f);
  }
  const p = Object.fromEntries(f.formatToParts(new Date(ts)).map((part) => [part.type, Number(part.value)]));
  return Date.UTC(p.year!, p.month! - 1, p.day!, p.hour!, p.minute!, p.second!) - (ts - (ts % 1000));
}

/** Instants where a zone's offset changes in a year, found hour by hour and narrowed to the second. */
function transitions(zone: string, year: number): number[] {
  const out: number[] = [];
  const end = Date.UTC(year + 1, 0, 1);
  let at = Date.UTC(year, 0, 1);
  let prev = offsetOf(at, zone);
  for (at += 3_600_000; at <= end; at += 3_600_000) {
    const now = offsetOf(at, zone);
    if (now === prev) continue;
    let lo = at - 3_600_000;
    let hi = at;
    while (hi - lo > 1000) {
      const mid = lo + Math.floor((hi - lo) / 2000) * 1000;
      if (offsetOf(mid, zone) === prev) lo = mid;
      else hi = mid;
    }
    out.push(hi);
    prev = now;
  }
  return out;
}

const instants: Array<[string, number, string, number, number]> = [];
const starts: Array<[string, string, number, number]> = [];
const dayStarts: Array<[string, number, string]> = [];
for (const zone of FOCUS) {
  for (const year of YEARS) {
    for (const t of transitions(zone, year)) {
      for (let delta = -2 * 3_600_000; delta <= 2 * 3_600_000; delta += 30 * 60_000) {
        for (const ts of [t + delta, t + delta - 1]) {
          const [weekday, hour] = localWeekdayHour(ts, zone);
          instants.push([zone, ts, localDate(ts, zone), weekday, hour]);
        }
      }
      const date = localDate(t, zone);
      for (const d of [addDays(date, -1), date, addDays(date, 1)]) {
        for (const hour of [0, 2, 23]) starts.push([zone, d, hour, startOf(d, zone, hour)]);
      }
    }
  }
  // Every day of a few years, so a day's start is right whatever happens that day.
  for (const year of [1970, 2026, 2027]) {
    let d = `${year}-01-01`;
    const days: number[] = [];
    while (d < `${year + 1}-01-01`) {
      days.push(startOf(d, zone));
      d = addDays(d, 1);
    }
    dayStarts.push([zone, year, sha(JSON.stringify(days))]);
  }
  // Random instants over two centuries, the same for every zone.
  let seed = 12345;
  for (let i = 0; i < 150; i++) {
    seed = (seed * 1103515245 + 12345) % 2 ** 31;
    const ts = Date.UTC(1900, 0, 1) + Math.floor((seed / 2 ** 31) * (Date.UTC(2100, 0, 1) - Date.UTC(1900, 0, 1)));
    const [weekday, hour] = localWeekdayHour(ts, zone);
    instants.push([zone, ts, localDate(ts, zone), weekday, hour]);
  }
}

const DATES = [
  "2026-01-15", "2026-02-28", "2026-02-29", "2028-02-29", "2100-02-29", "2000-02-29", "1900-02-29", "1900-01-01", "1899-12-31", "9998-12-31", "9999-01-01",
  "2026-13-01", "2026-00-05", "2026-02-30", "2026-04-31", "2026-1-01", "0001-01-01", "2026-12-31", "2026-01-01", "2026-06-30", "2026-07-31", " 2026-01-01",
  "2026-01-01 ", "2026-01-01T00:00", "2026/01/01", "", "20260101", "2026-01-32", "٢٠٢٦-01-01", "1999-12-31", "2024-03-31", "2026-10-31",
];
const dateMath = DATES.map((date) => ({
  date,
  isDate: isDate(date),
  plus: isDate(date) ? [-400, -366, -365, -31, -1, 0, 1, 28, 29, 31, 365, 366, 1000].map((n) => addDays(date, n)) : null,
  months: isDate(date) ? [-25, -12, -11, -1, 0, 1, 11, 12, 13].map((n) => addMonths(date, n)) : null,
}));

const NOWS = [
  Date.UTC(2026, 9, 6, 2), Date.UTC(2026, 9, 6, 12), Date.UTC(2026, 0, 1, 0), Date.UTC(2025, 11, 31, 23, 59, 59, 999), Date.UTC(2028, 1, 29, 12),
  Date.UTC(2028, 2, 1, 0, 30), Date.UTC(2026, 2, 8, 7), Date.UTC(2026, 2, 29, 1), Date.UTC(2026, 9, 25, 1), Date.UTC(2026, 10, 1, 5, 30),
  Date.UTC(2026, 3, 5, 15, 30), Date.UTC(2026, 9, 4, 16), Date.UTC(2026, 6, 31, 23), Date.UTC(1999, 11, 31, 23),
];
const RANGE_ZONES = ["UTC", "America/Toronto", "Europe/London", "Australia/Lord_Howe", "Asia/Kolkata", "Pacific/Chatham", "America/Santiago", "Pacific/Kiritimati", "-03:30"];
const INPUTS: Array<{ period?: string | null; from?: string | null; to?: string | null; interval?: string | null }> = [
  ...PERIODS.map((period) => ({ period })),
  ...PERIODS.map((period) => ({ period, interval: "week" })),
  {}, { period: null }, { period: "" }, { period: "nope" }, { period: "TODAY" }, { period: "today", interval: "hour" }, { period: "today", interval: "month" },
  { period: "12mo", interval: "day" }, { period: "year", interval: "nope" }, { period: "all", interval: "hour" },
  { from: "2026-03-07", to: "2026-03-09" }, { from: "2026-03-07", to: "2026-03-09", interval: "hour" }, { from: "2026-01-15", to: "2026-03-10", interval: "month" },
  { from: "2026-01-01", to: "2026-12-31" }, { from: "2026-01-01", to: "2026-04-03" }, { from: "2026-01-01", to: "2026-04-04" }, { from: "2025-12-29", to: "2026-01-04", interval: "week" },
  { from: "2026-10-05", to: "2026-10-01" }, { from: "2026-02-30", to: "2026-03-01" }, { from: "2026-01-01" }, { to: "2026-01-01" }, { from: "", to: "2026-01-01" },
  { from: "", to: "", period: "7d" }, { from: null, to: null, period: "today" }, { from: "1900-01-01", to: "1900-01-31" }, { from: "1900-01-01", to: "2026-01-01" },
  { from: "9998-12-01", to: "9998-12-31" }, { from: "2026-10-25", to: "2026-10-25", interval: "hour" }, { from: "2026-03-29", to: "2026-03-29" },
  { from: "2026-04-05", to: "2026-04-05" }, { from: "2026-09-06", to: "2026-09-06", interval: "hour" }, { from: "2028-02-29", to: "2028-02-29" },
  { from: "2026-01-01", to: "2026-03-01", interval: "hour" }, { from: "2026-01-01", to: "2026-01-01", interval: "week" },
];
const FIRST_DATES = [undefined, "2020-05-17", "2030-01-01", "", "1900-01-01"];
const ranges = [];
for (const zone of RANGE_ZONES) {
  for (const [n, now] of NOWS.entries()) {
    for (const [i, input] of INPUTS.entries()) {
      // Half the grid for UTC and Toronto; a spread of it for the other zones.
      if ((n + i) % (zone === "UTC" || zone === "America/Toronto" ? 2 : 6) !== 0) continue;
      for (const [f, firstDate] of FIRST_DATES.entries()) {
        if (f > 0 && input.period !== "all") continue;
        const range = resolveRange(input, zone, now, firstDate);
        const entry: Record<string, unknown> = { zone, now, input, firstDate: firstDate ?? null, range };
        if (range) {
          const b = buckets(range, zone);
          entry.buckets = { count: b.length, first: b[0] ?? null, sha256: sha(JSON.stringify(b)) };
          if ((n * 7 + i) % 10 === 0) {
            entry.compare = Object.fromEntries(
              (["previous", "year", "off", "custom", "nope"] as CompareMode[]).map((mode) => [mode, compareRange(range, mode, zone, { from: "2025-02-28", to: "2025-03-31" })]),
            );
          }
        }
        ranges.push(entry);
      }
    }
  }
}
const CUSTOM = [{}, { from: "2026-01-07", to: "2026-01-01" }, { from: "2026-01-01" }, { from: "2026-02-29", to: "2026-03-01" }, { from: "2026-01-01", to: "2026-01-01" }, { from: "", to: "" }, { from: null, to: "2026-01-01" }];
const compares = [];
for (const range of [resolveRange({ from: "2028-02-29", to: "2028-02-29" }, "UTC", 0)!, resolveRange({ from: "2024-02-01", to: "2024-02-29" }, "Europe/London", 0)!, resolveRange({ from: "2026-03-01", to: "2026-03-31", interval: "week" }, "America/Toronto", 0)!]) {
  for (const custom of CUSTOM) {
    for (const mode of ["previous", "year", "custom", "off"] as CompareMode[]) {
      for (const zone of ["UTC", "America/Toronto", "Asia/Kolkata"]) compares.push({ range, mode, zone, custom, compare: compareRange(range, mode, zone, custom) });
    }
  }
}

write("time", "Dates in a zone: isTimezone with each zone's local date, Monday-based weekday, and hour at fixed instants; instants and day starts around every offset change in the focus zones; date math; resolveRange with buckets (summarised, with a SHA-256 of their JSON) and compareRange.", {
  periods: PERIODS,
  sampleTimes: SAMPLE_TIMES,
  zones,
  instants,
  starts,
  dayStarts,
  dates: dateMath,
  ranges,
  compares,
});

// ---------------------------------------------------------------- geo

const enc = (o: unknown) => Buffer.from(JSON.stringify(o), "latin1").toString("base64");
const utf8 = (o: unknown) => Buffer.from(JSON.stringify(o), "utf8").toString("base64");
const HEADER_SETS: Array<Record<string, string>> = [
  {},
  { "x-vercel-ip-country": "US", "x-vercel-ip-country-region": "CA", "x-vercel-ip-city": "San%20Francisco" },
  { "x-vercel-ip-country": "ca", "x-vercel-ip-country-region": "on", "x-vercel-ip-city": "Toronto" },
  { "x-vercel-ip-country": "DE", "x-vercel-ip-country-region": "BY", "x-vercel-ip-city": "M%C3%BCnchen" },
  { "x-vercel-ip-country": "US", "x-vercel-ip-country-region": "US-CA", "x-vercel-ip-city": "%E0%A4%A" },
  { "x-vercel-ip-country": "US", "x-vercel-ip-city": "%FF%FE" },
  { "x-vercel-ip-country": "XX", "x-vercel-ip-country-region": "CA", "x-vercel-ip-city": "Nowhere" },
  { "x-vercel-ip-country": "T1", "x-vercel-ip-city": "Tor" },
  { "x-vercel-ip-country": "USA", "x-vercel-ip-country-region": "California", "x-vercel-ip-city": "Los Angeles" },
  { "x-vercel-ip-country": "1A" },
  { "x-vercel-ip-country": "u", "x-vercel-ip-city": "x" },
  { "x-vercel-ip-country": "GB", "x-vercel-ip-country-region": "ENG", "x-vercel-ip-city": "London" },
  { "x-vercel-ip-country": "GB", "x-vercel-ip-country-region": "Greater London Area And Beyond Region With A Very Long Name That Goes On And On For Ever", "x-vercel-ip-city": "c".repeat(150) },
  { "x-vercel-ip-country": "JP", "x-vercel-ip-country-region": "13", "x-vercel-ip-city": "%E6%9D%B1%E4%BA%AC" },
  { "x-vercel-ip-country": "FR", "x-vercel-ip-country-region": "%20IDF%20", "x-vercel-ip-city": "%20Paris%20" },
  { "x-vercel-ip-country": "FR", "x-vercel-ip-country-region": "fr-idf" },
  { "x-vercel-ip-country": "FR", "x-vercel-ip-country-region": "F-IDF" },
  { "x-vercel-ip-country": "FR", "x-vercel-ip-country-region": "1234" },
  { "x-vercel-ip-country": "", "cf-ipcountry": "NZ", "cf-region-code": "AUK", "cf-ipcity": "Auckland" },
  { "cf-ipcountry": "NZ", "cf-region-code": "AUK", "cf-ipcity": "Auckland" },
  { "cf-ipcountry": "XX" },
  { "cf-ipcountry": "T1", "cf-ipcity": "Tor" },
  { "cf-ipcountry": "br", "cf-region-code": "SP", "cf-ipcity": "S%C3%A3o%20Paulo" },
  { "x-nf-geo": enc({ city: "Paris", country: { code: "FR", name: "France" }, subdivision: { code: "IDF", name: "Ile-de-France" } }) },
  { "x-nf-geo": utf8({ city: "Zürich", country: { code: "CH" }, subdivision: { code: "ZH" } }) },
  { "x-nf-geo": enc({ city: "Zürich", country: { code: "CH" } }) },
  { "x-nf-geo": enc({ country: { code: "us" } }) },
  { "x-nf-geo": enc({}) },
  { "x-nf-geo": enc(null) },
  { "x-nf-geo": enc(5) },
  { "x-nf-geo": enc("text") },
  { "x-nf-geo": enc([1, 2]) },
  { "x-nf-geo": enc({ country: "FR" }) },
  { "x-nf-geo": enc({ country: { code: 5 } }) },
  { "x-nf-geo": enc({ country: { code: "FR" }, subdivision: { code: 7 } }) },
  { "x-nf-geo": enc({ country: { code: "FR" }, city: 7 }) },
  { "x-nf-geo": enc({ country: { code: "" }, city: 7 }) },
  { "x-nf-geo": enc({ country: { code: null }, subdivision: null, city: null }) },
  { "x-nf-geo": "not base64!" },
  { "x-nf-geo": "e30" },
  { "x-nf-geo": "e30=" },
  { "x-nf-geo": " e 3 0 = " },
  { "x-nf-geo": "e30==" },
  { "x-nf-geo": "e" },
  { "x-nf-geo": "e3=0" },
  { "x-nf-geo": Buffer.from("not json").toString("base64") },
  { "x-nf-geo": enc({ city: "Paris", country: { code: "FR" } }).replace(/=+$/, "") },
];
const geo = HEADER_SETS.map((headers) => ({ headers, location: locationFromHeaders(new Headers(headers)) }));
const LOOKUPS: Array<{ headers: Record<string, string>; ip: string; found: unknown; throws?: boolean }> = [
  { headers: {}, ip: "1.2.3.4", found: { country: "CA", region: "Ontario", city: "Toronto" } },
  { headers: {}, ip: "1.2.3.4", found: { country: "us", region: "ca", city: "Mountain View" } },
  { headers: {}, ip: "1.2.3.4", found: null },
  { headers: {}, ip: "", found: { country: "CA" } },
  { headers: {}, ip: "1.2.3.4", found: { country: "CA" }, throws: true },
  { headers: {}, ip: "1.2.3.4", found: {} },
  { headers: {}, ip: "1.2.3.4", found: { country: 5 } },
  { headers: {}, ip: "1.2.3.4", found: { region: "ON", city: "Toronto" } },
  { headers: { "x-vercel-ip-country": "US" }, ip: "1.2.3.4", found: { country: "CA" } },
  { headers: { "x-vercel-ip-country": "XX" }, ip: "1.2.3.4", found: { country: "CA", region: "QC" } },
  { headers: { "x-nf-geo": "bad" }, ip: "1.2.3.4", found: { country: "DE", city: "Berlin" } },
];
const located = [];
for (const c of LOOKUPS) {
  const lookup = (() => {
    if (c.throws) throw new Error("broken");
    return c.found as never;
  }) as never;
  located.push({ ...c, location: await locate(new Headers(c.headers), c.ip, lookup) });
}
located.push({ headers: {}, ip: "1.2.3.4", found: null, noLookup: true, location: await locate(new Headers({}), "1.2.3.4") });

// A small MaxMind DB, written here, read back with mmdb-lib (which the TypeScript server uses).
type Value = string | number | boolean | Value[] | { [key: string]: Value } | { double: number } | { float: number } | { int32: number } | { uint64: bigint } | { bytes: number[] };
function mmdbEncode(value: Value, cache: Map<string, number>, out: number[]): void {
  const key = JSON.stringify(value, (_, v) => (typeof v === "bigint" ? `${v}n` : v));
  const known = cache.get(key);
  if (known !== undefined && typeof value === "object") {
    pointer(known, out);
    return;
  }
  const at = out.length;
  const control = (type: number, size: number, payload: number[]) => {
    const head: number[] = [];
    const ext = type > 7 ? [type - 7] : [];
    let sizeBits = size;
    const extra: number[] = [];
    if (size >= 65821) {
      sizeBits = 31;
      const n = size - 65821;
      extra.push((n >> 16) & 255, (n >> 8) & 255, n & 255);
    } else if (size >= 285) {
      sizeBits = 30;
      const n = size - 285;
      extra.push((n >> 8) & 255, n & 255);
    } else if (size >= 29) {
      sizeBits = 29;
      extra.push(size - 29);
    }
    head.push(((type > 7 ? 0 : type) << 5) | sizeBits, ...ext, ...extra);
    out.push(...head, ...payload);
  };
  const be = (n: bigint | number, bytes: number) => {
    const b: number[] = [];
    let v = BigInt(n);
    for (let i = 0; i < bytes; i++) {
      b.unshift(Number(v & 255n));
      v >>= 8n;
    }
    while (b.length && b[0] === 0) b.shift();
    return b;
  };
  if (typeof value === "string") {
    const bytes = [...Buffer.from(value, "utf8")];
    control(2, bytes.length, bytes);
  } else if (typeof value === "boolean") {
    control(14, value ? 1 : 0, []);
  } else if (typeof value === "number") {
    const bytes = be(value, value > 65535 ? 4 : 2);
    control(value > 65535 ? 6 : 5, bytes.length, bytes);
  } else if (Array.isArray(value)) {
    control(11, value.length, []);
    for (const item of value) mmdbEncode(item, cache, out);
  } else if ("double" in value) {
    const b = Buffer.alloc(8);
    b.writeDoubleBE(value.double as number);
    control(3, 8, [...b]);
  } else if ("float" in value) {
    const b = Buffer.alloc(4);
    b.writeFloatBE(value.float as number);
    control(15, 4, [...b]);
  } else if ("int32" in value) {
    const b = Buffer.alloc(4);
    b.writeInt32BE(value.int32 as number);
    control(8, 4, [...b]);
  } else if ("uint64" in value) {
    const bytes = be(value.uint64 as bigint, 16);
    control((value.uint64 as bigint) >= 2n ** 64n ? 10 : 9, bytes.length, bytes);
  } else if ("bytes" in value) {
    control(4, (value.bytes as number[]).length, value.bytes as number[]);
  } else {
    const entries = Object.entries(value);
    control(7, entries.length, []);
    for (const [k, v] of entries) {
      mmdbEncode(k, cache, out);
      mmdbEncode(v as Value, cache, out);
    }
  }
  if (typeof value === "object") cache.set(key, at);
}
function pointer(offset: number, out: number[]): void {
  if (offset < 2048) out.push((1 << 5) | (0 << 3) | (offset >> 8), offset & 255);
  else if (offset < 526336) {
    const n = offset - 2048;
    out.push((1 << 5) | (1 << 3) | (n >> 16), (n >> 8) & 255, n & 255);
  } else if (offset < 134744064) {
    const n = offset - 526336;
    out.push((1 << 5) | (2 << 3) | (n >> 24), (n >> 16) & 255, (n >> 8) & 255, n & 255);
  } else out.push((1 << 5) | (3 << 3), (offset >> 24) & 255, (offset >> 16) & 255, (offset >> 8) & 255, offset & 255);
}
function mmdbWrite(ipVersion: 4 | 6, recordSize: 24 | 28 | 32, networks: Array<[string, number, Value]>): Buffer {
  const bits = (ip: string): number[] => {
    if (ip.includes(":")) {
      const [l, r = ""] = ip.split("::");
      const left = l ? l.split(":") : [];
      const right = r ? r.split(":") : [];
      const groups = ip.includes("::") ? [...left, ...Array(8 - left.length - right.length).fill("0"), ...right] : left;
      return groups.flatMap((g) => [...parseInt(g, 16).toString(2).padStart(16, "0")].map(Number));
    }
    const v4 = ip.split(".").flatMap((o) => [...(+o).toString(2).padStart(8, "0")].map(Number));
    return ipVersion === 6 ? [...Array(96).fill(0), ...v4] : v4;
  };
  type Node = { left: Node | number | null; right: Node | number | null };
  const root: Node = { left: null, right: null };
  const data: number[] = [];
  const cache = new Map<string, number>();
  for (const [ip, prefix, value] of networks) {
    const offset = data.length;
    mmdbEncode(value, cache, data);
    const path = bits(ip).slice(0, ipVersion === 6 && !ip.includes(":") ? prefix + 96 : prefix);
    let node = root;
    for (let i = 0; i < path.length - 1; i++) {
      const side = path[i] ? "right" : "left";
      if (typeof node[side] !== "object" || node[side] === null) node[side] = { left: null, right: null };
      node = node[side] as Node;
    }
    node[path[path.length - 1] ? "right" : "left"] = -1 - offset;
  }
  const nodes: Node[] = [];
  const number = new Map<Node, number>();
  const walk = (n: Node) => {
    number.set(n, nodes.length);
    nodes.push(n);
    for (const side of ["left", "right"] as const) if (n[side] && typeof n[side] === "object") walk(n[side] as Node);
  };
  walk(root);
  const count = nodes.length;
  const recordValue = (r: Node | number | null) => (r === null ? count : typeof r === "number" ? count + 16 + (-1 - r) : number.get(r)!);
  const tree: number[] = [];
  for (const n of nodes) {
    const l = recordValue(n.left);
    const r = recordValue(n.right);
    if (recordSize === 24) tree.push((l >> 16) & 255, (l >> 8) & 255, l & 255, (r >> 16) & 255, (r >> 8) & 255, r & 255);
    else if (recordSize === 28) tree.push((l >> 16) & 255, (l >> 8) & 255, l & 255, ((l >> 20) & 0xf0) | ((r >> 24) & 0x0f), (r >> 16) & 255, (r >> 8) & 255, r & 255);
    else tree.push((l >>> 24) & 255, (l >> 16) & 255, (l >> 8) & 255, l & 255, (r >>> 24) & 255, (r >> 16) & 255, (r >> 8) & 255, r & 255);
  }
  const meta: number[] = [];
  mmdbEncode({ node_count: count, record_size: recordSize, ip_version: ipVersion, database_type: "Runlight-Test", languages: ["en", "de"], binary_format_major_version: 2, binary_format_minor_version: 0, build_epoch: { uint64: 1759708800n }, description: { en: "A test database" } }, new Map(), meta);
  return Buffer.from([...tree, ...Array(16).fill(0), ...data, ...Buffer.from("\xAB\xCD\xEFMaxMind.com", "latin1"), ...meta]);
}

const city = (iso: string, sub: Value | null, name: string, extra: Record<string, Value> = {}): Value => ({
  city: { geoname_id: 6167865, names: { en: name, de: name + " (de)" } },
  country: { iso_code: iso, geoname_id: 6251999, names: { en: iso } },
  ...(sub ? { subdivisions: [sub] } : {}),
  location: { latitude: { double: 43.7 }, longitude: { double: -79.42 }, accuracy_radius: 5, time_zone: "America/Toronto" },
  ...extra,
});
const filler = "x".repeat(3000);
const NETWORKS: Array<[string, number, Value]> = [
  ["24.114.0.0", 16, city("CA", { names: { en: "Ontario" } }, "Toronto (Old Toronto)")],
  ["8.8.8.0", 24, city("US", { iso_code: "CA", names: { en: "California" } }, "Mountain View")],
  ["81.2.69.0", 24, city("GB", { iso_code: "ENG", names: { en: "England" } }, "London", { padding: filler })],
  ["2.125.160.0", 19, city("GB", null, "Boxford ( West Berkshire )")],
  ["175.16.199.0", 24, city("CN", { iso_code: "22", names: { en: "Jilin Sheng" } }, "Changchun")],
  ["89.160.20.0", 28, city("SE", { names: { en: "Östergötland County" } }, "Linköping")],
  ["10.0.0.0", 8, { country: { iso_code: "" } }],
  ["11.1.0.0", 16, { country: { names: { en: "Nowhere" } } }],
  ["192.0.2.0", 24, { types: { yes: true, no: false, f: { float: 1.5 }, neg: { int32: -42 }, big: { uint64: 18446744073709551615n }, huge: { uint64: 2n ** 100n }, small: { uint64: 7n }, list: [1, "two", [3], {}] }, country: { iso_code: "ZZ" } }],
  ["198.51.100.0", 24, city("CA", { names: { en: "Ontario" } }, "Toronto (Old Toronto)")],
  ["2001:db8::", 32, city("DE", { iso_code: "BE", names: { en: "Berlin" } }, "Berlin")],
  ["2a02:1234::", 32, city("FR", { names: { en: "Île-de-France" } }, "Paris")],
];
const IPS = ["24.114.0.1", "24.114.255.255", "24.115.0.1", "8.8.8.8", "8.8.4.4", "81.2.69.160", "2.125.160.216", "175.16.199.1", "89.160.20.112", "89.160.20.128", "10.0.0.1", "11.1.2.3", "192.0.2.1", "198.51.100.7", "2001:db8::1", "2001:db8:ffff::1", "2a02:1234:5678::1", "::ffff:8.8.8.8", "::8.8.8.8", "1.1.1.1", "0.0.0.0", "255.255.255.255", "::1", "::"];
const databases = [];
for (const [ipVersion, recordSize] of [[6, 24], [6, 28], [6, 32], [4, 24], [4, 28]] as const) {
  const nets = ipVersion === 4 ? NETWORKS.filter(([ip]) => !ip.includes(":")) : NETWORKS;
  const bytes = mmdbWrite(ipVersion, recordSize, nets);
  const reader = new Reader(bytes);
  const lookup = lookupFrom(reader as never);
  const ips = ipVersion === 4 ? IPS.filter((ip) => !ip.includes(":")) : IPS;
  databases.push({
    ipVersion,
    recordSize,
    base64: bytes.toString("base64"),
    records: ips.map((ip) => ({ ip, record: reader.get(ip), location: lookup(ip) })),
  });
}

write("geo", "Location from Vercel, Cloudflare, and Netlify headers (locationFromHeaders), with a lookup behind them (locate), and the server's MMDB lookup: small MaxMind DBs written by the fixture script, with what mmdb-lib reads from them and what lookupFrom makes of it. A uint64 or uint128 past 2^53 is written as its decimal text.", {
  headers: geo,
  located,
  databases,
});

// ---------------------------------------------------------------- zip and csv

const CELLS: unknown[] = [
  "plain", "", null, undefined, 0, -0, 1, -1, 1.5, -1.5, 0.1 + 0.2, 1e21, 1e-7, 123456789012345680000, NaN, Infinity, -Infinity, true, false,
  "=SUM(A1)", "+1", "-2", "-2.5", "-2.", "-.5", "@user", "\tTab", "\rCR", "-", "+", "=", "a,b", 'say "hi"', "line\nbreak", "cr\rhere", "crlf\r\n", "café",
  "\u{1F600}", "\ud800 lone", "'quoted'", " lead", "trail ", "=1+1,\"x\"", "-12a", "12-", "1.2.3", "-0", "00012", " =x", "\n=x", [1, 2], [null, "a"], [],
  ["nested", [1, 2]], { a: 1 }, "x".repeat(300),
];
const csvs = [
  { header: ["value", "visitors", "pageviews"], rows: [["/pricing", 1, 1], ["/café", 2, 3]] },
  { header: [], rows: [] },
  { header: ["only"], rows: [] },
  { header: ["a"], rows: [[]] },
  { header: ["=bad", "-1", "+x"], rows: CELLS.map((cell, i) => [i, cell]) },
  { header: ["h"], rows: [CELLS] },
];
const csvCases = csvs.map((c) => ({ ...c, csv: csv(c.header, c.rows as unknown[][]) }));
const rowCases = CELLS.map((cell) => ({ cell, row: csvRow([cell]) }));
const zipCases = [
  { files: [], now: Date.UTC(2026, 9, 6, 14, 30, 59) },
  { files: [{ name: "overview.csv", text: "a,b\r\n1,2\r\n" }], now: Date.UTC(2026, 9, 6, 14, 30, 59) },
  { files: [{ name: "café.csv", text: "\u{1F600}\ud800" }, { name: "empty.csv", text: "" }, { name: "page.csv", text: csvCases[0]!.csv }], now: Date.UTC(1980, 0, 1) },
  { files: [{ name: "old.txt", text: "x" }], now: Date.UTC(1979, 11, 31, 23, 59, 58) },
  { files: [{ name: "far.txt", text: "y" }], now: Date.UTC(2107, 11, 31, 23, 59, 59) },
  { files: [{ name: "beyond.txt", text: "z" }], now: Date.UTC(2108, 0, 1) },
  { files: [{ name: "neg.txt", text: "w" }], now: -1500 },
  { files: Array.from({ length: 12 }, (_, i) => ({ name: `f${i}.csv`, text: "row\r\n".repeat(i * 50) })), now: Date.UTC(2026, 1, 28, 23, 59, 1) },
];
/** Cells JSON cannot carry (undefined, NaN, the infinities, and -0) are written as {"js": "NaN"} and the like. */
const cellJson = (cell: unknown): unknown => {
  if (cell === undefined) return { js: "undefined" };
  if (typeof cell === "number" && !Number.isFinite(cell)) return { js: String(cell) };
  if (Object.is(cell, -0)) return { js: "-0" };
  if (Array.isArray(cell)) return cell.map(cellJson);
  return cell;
};
write("zip", "CSV rows and files (csvRow, csv) and stored ZIP files (zip, as base64) for fixed times. A cell JSON cannot carry is written as {\"js\": \"undefined\"}, {\"js\": \"NaN\"}, {\"js\": \"Infinity\"}, {\"js\": \"-Infinity\"}, or {\"js\": \"-0\"}.", {
  rows: rowCases.map((c) => ({ cell: cellJson(c.cell), row: c.row })),
  csvs: csvCases.map((c) => ({ header: c.header, rows: (c.rows as unknown[][]).map((row) => row.map(cellJson)), csv: c.csv })),
  zips: zipCases.map((c) => ({ ...c, base64: Buffer.from(zip(c.files, new Date(c.now))).toString("base64") })),
});

// ---------------------------------------------------------------- brand and version

write("version", "The SDK's version, the HTTP API's version, and the dashboard icon.", { version: VERSION, apiVersion: API_VERSION, icon: RUNLIGHT_ICON });
