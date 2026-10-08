---
title: Ask your AI
description: Connect any MCP client, such as Claude or Cursor, to Runlight with a read-only token and ask about your stats in plain words.
group: Features
order: 10
---

Runlight has a built-in MCP server at `/runlight/mcp`, next to the dashboard. Once an AI assistant is connected to it, you can ask about things you would otherwise click around for, such as how last week compared with the week before, which pages people from Google read, what is converting, and whether the spike on Tuesday came from Hacker News.

The server is part of `rl.routes()`, so it runs wherever your dashboard does.

To ask from the dashboard itself with no assistant app of your own, use [the assistant](/docs/dashboard/#the-assistant) behind the robot button, which uses the same tools with a key you add in Settings.

## Make a token

In the dashboard, go to **Settings** and open **API and AI**. Name the token after what will use it, like "Claude" or "Weekly script", and create it. If you track several sites you can limit a token to one of them.

Copy the token when it appears. Runlight keeps only a fingerprint of it, so it can show the token just this once. The page also fills in the setup below with your own address and token.

Tokens are read-only. A token sees the same numbers the dashboard shows and can list short links with their clicks. It cannot change settings, goals, or links, and it cannot make or delete tokens or see your mail settings and share links. A token you delete in the same place stops working at once, and the list shows when each token was last used.

## Connect your assistant

In each of these, replace the address with your own and `rl_...` with your token.

For **Claude Code**, run this command.

```bash
claude mcp add --transport http runlight https://example.com/runlight/mcp --header "Authorization: Bearer rl_..."
```

For **Cursor**, add this to `~/.cursor/mcp.json` or a project's `.cursor/mcp.json`.

```json
{
  "mcpServers": {
    "runlight": {
      "url": "https://example.com/runlight/mcp",
      "headers": { "Authorization": "Bearer rl_..." }
    }
  }
}
```

For **VS Code**, add this to `.vscode/mcp.json`.

```json
{
  "servers": {
    "runlight": {
      "type": "http",
      "url": "https://example.com/runlight/mcp",
      "headers": { "Authorization": "Bearer rl_..." }
    }
  }
}
```

**Claude Desktop** connects through [mcp-remote](https://www.npmjs.com/package/mcp-remote). Add this to `claude_desktop_config.json`.

```json
{
  "mcpServers": {
    "runlight": {
      "command": "npx",
      "args": ["mcp-remote", "https://example.com/runlight/mcp", "--header", "Authorization:${AUTH_HEADER}"],
      "env": { "AUTH_HEADER": "Bearer rl_..." }
    }
  }
}
```

Any other client that speaks MCP over Streamable HTTP and can send a header works the same way.

## Connecting with OAuth

The connectors in the Claude and ChatGPT web apps sign in with OAuth instead of a pasted token, and Runlight supports that too. Add your MCP server address as a custom connector. The app sends you to a Runlight page that asks you to allow it, after you sign in if you need to, and lets you limit it to one site. It then gets a read-only token of its own, which appears in **Settings**, **API and AI** with "(OAuth)" after its name. Deleting it there disconnects the app.

The standalone server needs nothing more. Inside your own app, OAuth clients also look for two documents at your site's root, so route `/.well-known/oauth-authorization-server` and `/.well-known/oauth-protected-resource` to Runlight as well. In Next.js that is one more route file.

```ts file=app/.well-known/[...path]/route.ts
import { rl } from "@/lib/runlight";
export const { GET, OPTIONS } = rl.routes();
```


## What it can answer

| Tool | What it reads |
| --- | --- |
| `list_sites` | The sites the token can read, with their timezones. |
| `get_stats` | Visitors, visits, pageviews, views per visit, bounce rate, and visit duration, compared with the period before. |
| `get_timeseries` | The same numbers by hour, day, week, or month. |
| `get_breakdown` | The top pages, entry and exit pages, referrers, sources, channels, UTM tags, countries, regions, cities, browsers, systems, devices, screens, languages, events, and AI agents. |
| `get_visit_times` | Visits by weekday and hour. |
| `get_realtime` | How many people are on the site now, the pages being read, and where visits came from, never who. |
| `list_goals`, `get_goal` | Conversions, rates, and revenue for every goal, or one goal split by channel, source, and page. |
| `get_journeys` | The paths visits take through the site, step by step, from or to a page if you like. |
| `list_funnels` | Each funnel's steps and how many visits reached each one. |
| `get_event_properties` | The values sent with an event, such as which links were clicked or which files downloaded. |
| `list_links` | Short links and their clicks. |

Every tool takes the dashboard's periods (`today`, `7d`, `30d`, `month`, `last_month`, `12mo`, `all`, and the rest) or dates. Each one also takes a comparison and filters such as `channel:is:Organic Search` or `page:contains:/blog`. Assistants learn these from the tool descriptions, so you can simply ask.

Here are some things to try.

- "How did last month compare with the month before, and what changed most?"
- "Which blog posts do people from Google read longest?"
- "Where do the visitors who buy come from?"
- "Did anything unusual happen this week?"

## Scripts

The same token works with the [HTTP API](/docs/api/), so you can use it in your own scripts and dashboards.

```bash
curl "https://example.com/runlight/api/stats?period=7d" -H "Authorization: Bearer rl_..."
```
