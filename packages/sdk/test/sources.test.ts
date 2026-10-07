import assert from "node:assert/strict";
import { test } from "node:test";
import { attribute, parsePage, sourceForHost } from "../src/sources.js";

const visit = (url: string, referrer = "", internal: string[] = []) => attribute(parsePage(new URL(url)), referrer, internal);

test("no referrer and no tags is direct", () => {
  assert.deepEqual(visit("https://example.com/"), { referrerHost: "", referrerPath: "", source: "", channel: "Direct" });
});

test("search engines are organic search, by the most specific host", () => {
  assert.equal(visit("https://example.com/", "https://www.google.co.uk/").channel, "Organic Search");
  assert.equal(visit("https://example.com/", "https://www.google.co.uk/").source, "Google");
  assert.equal(sourceForHost("mail.google.com")?.name, "Gmail");
  assert.equal(sourceForHost("gemini.google.com")?.name, "Gemini");
});

test("a click id on a search referrer is paid search", () => {
  assert.equal(visit("https://example.com/?gclid=abc", "https://www.google.com/").channel, "Paid Search");
  assert.equal(visit("https://example.com/?utm_source=google&utm_medium=cpc").channel, "Paid Search");
});

test("AI assistants are the AI channel, by referrer or by tag", () => {
  assert.deepEqual(visit("https://example.com/post", "https://chatgpt.com/"), {
    referrerHost: "chatgpt.com",
    referrerPath: "/",
    source: "ChatGPT",
    channel: "AI",
  });
  const tagged = visit("https://example.com/post?utm_source=chatgpt.com");
  assert.equal(tagged.source, "ChatGPT");
  assert.equal(tagged.channel, "AI");
  assert.equal(visit("https://example.com/", "https://www.perplexity.ai/search/x").source, "Perplexity");
  assert.equal(visit("https://example.com/", "https://claude.ai/").channel, "AI");
});

test("social, email, campaigns, and referrals", () => {
  assert.equal(visit("https://example.com/", "https://news.ycombinator.com/item?id=1").source, "Hacker News");
  assert.equal(visit("https://example.com/", "https://t.co/abc").channel, "Social");
  assert.equal(visit("https://example.com/?utm_source=weekly&utm_medium=email").channel, "Email");
  assert.equal(visit("https://example.com/?utm_source=newsletter").channel, "Email");
  assert.equal(visit("https://example.com/?utm_source=partner&utm_campaign=launch").channel, "Campaign");
  assert.equal(visit("https://example.com/?utm_source=partner&utm_campaign=launch").source, "partner");
  assert.equal(visit("https://example.com/", "https://someblog.net/post").channel, "Referral");
  assert.equal(visit("https://example.com/", "https://someblog.net/post").source, "someblog.net");
  assert.equal(visit("https://example.com/?ref=producthunt").source, "Product Hunt");
});

test("the site's own hosts are not a referrer", () => {
  assert.equal(visit("https://example.com/b", "https://www.example.com/a").channel, "Direct");
  assert.equal(visit("https://example.com/b", "https://shop.example.com/a", ["shop.example.com"]).referrerHost, "");
  assert.equal(visit("https://example.com/b", "not a url").channel, "Direct");
});

test("only the path and campaign parameters are kept from a URL", () => {
  const page = parsePage(new URL("https://www.example.com/a/b?email=x@y.z&utm_campaign=spring&fbclid=123#top"));
  assert.equal(page.hostname, "example.com");
  assert.equal(page.path, "/a/b#top");
  assert.equal(page.utm.campaign, "spring");
  assert.equal(page.paid, true);
  assert.ok(!JSON.stringify(page).includes("x@y.z"));
  assert.ok(!JSON.stringify(page).includes("123"));
});

test("app referrers, email click trackers, and webmail are named", () => {
  assert.equal(sourceForHost("com.google.android.gm")?.name, "Gmail");
  assert.equal(visit("https://example.com/", "android-app://com.google.android.gm/").source, "Gmail");
  assert.equal(visit("https://example.com/", "https://com.google.android.gm/").channel, "Email");
  assert.equal(visit("https://example.com/", "https://15a992bb.click.convertkit-mail4.com/x").source, "Kit");
  assert.equal(visit("https://example.com/", "https://15a992bb.click.convertkit-mail4.com/x").channel, "Email");
  assert.equal(visit("https://example.com/", "https://mail01.orange.fr/").source, "mail01.orange.fr");
  assert.equal(visit("https://example.com/", "https://mail01.orange.fr/").channel, "Email");
  assert.equal(visit("https://example.com/", "https://mail.aol.com/").channel, "Email");
  assert.equal(visit("https://example.com/", "https://mailbox.org/").channel, "Referral", "only mail. or webmail. prefixes count");
});
