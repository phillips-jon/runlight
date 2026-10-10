---
title: AI sources and agents
description: Runlight counts the people who arrive from ChatGPT and Claude, and it sees the AI agents that read your pages without running any JavaScript.
group: Features
order: 7
---

AI shows up in your traffic in two ways, and Runlight counts both.

## People who came from an AI

When someone clicks a link in an answer from ChatGPT, Claude, Perplexity, Gemini, Copilot, Meta AI, Grok, DeepSeek, Mistral, You.com, or Phind, the visit gets that source and the **AI** channel. It counts toward visitors and conversions like any other visit, and you can filter by it.

## Agents that read your pages

An AI answering a question often fetches your page itself. Agents do not run JavaScript, so the tracker never sees them. To count them from your server, pass each page request to `rl.observe(request)`.

```ts file=proxy.ts
import { rl } from "@/lib/runlight";

export async function proxy(request: Request) {
  void rl.observe(request);
  return (await rl.linkDomainResponse(request)) ?? undefined;
}
```

This is Next.js middleware, which lives in `middleware.ts` before Next.js 16. In Express, use `app.use(observer(rl))` from `@runlight/sdk/node`. In the other languages the middleware or filter that serves Runlight usually records agents too, and each language’s page, from [PHP](/docs/php/) to [Rust](/docs/rust/), shows how. A site that runs no Runlight of its own can report them from a [CMS plugin](/docs/wordpress/) or from its [web server’s access log](/docs/server/#ai-agents-from-a-log).

`observe` records GET requests for pages from known agents and ignores everything else, including images, scripts, and styles. It never throws, so it is safe to call on every request. Leave it unawaited and it will not slow the response.

The **AI agents** box sorts what it sees into two groups and shows which pages each agent read. The first group fetches a page because a person asked something right now (ChatGPT-User, Claude-User, Perplexity-User, MistralAI-User, and Meta’s fetcher). The second group is crawlers that gather pages ahead of time (GPTBot, ClaudeBot, PerplexityBot, OAI-SearchBot, Amazonbot, CCBot, and others). Runlight keeps these fetches out of visitor and pageview numbers.
