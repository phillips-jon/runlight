---
title: AI sources and agents
description: People who arrive from ChatGPT and Claude, and the AI agents that read your pages without running any JavaScript.
group: Features
order: 7
---

AI shows up in your traffic in two ways, and Runlight counts both.

## People who came from an AI

When someone clicks a link in an answer from ChatGPT, Claude, Perplexity, Gemini, Copilot, Meta AI, Grok, DeepSeek, Mistral, You.com, or Phind, the visit gets that source and the **AI** channel. It is an ordinary visit in every other way: it counts toward visitors, it can convert, and you can filter by it.

## Agents that read your pages

An AI answering a question often fetches your page itself, and agents do not run JavaScript, so the tracker never sees them. Runlight can, from your server. Pass each page request to `rl.observe(request)`:

```ts file=proxy.ts
import { rl } from "@/lib/runlight";

export async function proxy(request: Request) {
  void rl.observe(request);
  return (await rl.linkDomainResponse(request)) ?? undefined;
}
```

That is Next.js middleware (`middleware.ts` before Next.js 16). In Express, use `app.use(observer(rl))` from `@runlight/sdk/node`.

`observe` records only GET requests for pages (not images, scripts, or styles) from known agents, ignores everything else, and never throws, so it is safe on every request. It does not slow the response: don’t await it.

The **AI agents** box splits what it sees into agents fetching a page because a person asked something right now (ChatGPT-User, Claude-User, Perplexity-User, MistralAI-User, and Meta’s fetcher) and crawlers gathering pages ahead of time (GPTBot, ClaudeBot, PerplexityBot, OAI-SearchBot, Amazonbot, CCBot, and others), and shows which pages each one read. These fetches are kept out of visitor and pageview numbers.
