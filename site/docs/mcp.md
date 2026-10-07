---
title: Ask your AI
description: Connect Claude, Cursor, or any MCP client to Runlight with a read-only token, then ask about your stats in plain words.
group: Features
order: 10
---

Runlight has an MCP server built in, at `/runlight/mcp` next to the dashboard. Connect an AI assistant to it and ask what you would otherwise click around for: how last week compared with the week before, which pages people from Google read, what is converting, or whether the spike on Tuesday came from Hacker News.

There is nothing extra to run. The server is part of `rl.routes()`, so it is wherever your dashboard is.

## Make a token

Open the dashboard, then **Settings**, then **API and AI**. Name the token after what will use it, like "Claude" or "Weekly script", and create it. If you track several sites you can limit a token to one of them.

The token is shown once. Copy it then; Runlight keeps only a fingerprint of it, so it cannot show it again. The page also fills in the setup below with your own address and token.

A token can only read. It sees the same numbers the dashboard shows, and it can list short links and their clicks, but it cannot change settings, goals, or links, cannot see your mail settings or share links, and cannot make or delete tokens. Delete it in the same place and it stops working at once. The list shows when each token was last used.

## Connect your assistant

In each of these, replace the address with your own and `rl_...` with your token.

**Claude Code**

```bash
claude mcp add --transport http runlight https://example.com/runlight/mcp --header "Authorization: Bearer rl_..."
```

**Cursor**, in `~/.cursor/mcp.json` or a project's `.cursor/mcp.json`:

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

**VS Code**, in `.vscode/mcp.json`:

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

**Claude Desktop**, through [mcp-remote](https://www.npmjs.com/package/mcp-remote), in `claude_desktop_config.json`:

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

Any other client that speaks MCP over Streamable HTTP and can send a header works the same way. Apps that only connect with OAuth, like the connectors in the Claude and ChatGPT web apps, cannot send a token yet.

## What it can answer

| Tool | What it reads |
| --- | --- |
| `list_sites` | The sites the token can read, with their timezones. |
| `get_stats` | Visitors, visits, pageviews, views per visit, bounce rate, and visit duration, compared with the period before. |
| `get_timeseries` | The same numbers by hour, day, week, or month. |
| `get_breakdown` | The top pages, entry and exit pages, referrers, sources, channels, UTM tags, countries, regions, cities, browsers, systems, devices, screens, languages, events, and AI agents. |
| `get_visit_times` | Visits by weekday and hour. |
| `get_realtime` | Who is on the site now, what they are reading, and where they came from. |
| `list_goals`, `get_goal` | Conversions, rates, and revenue, and one goal by channel, source, and page. |
| `list_links` | Short links and their clicks. |

Every tool takes the dashboard's periods (`today`, `7d`, `30d`, `month`, `last_month`, `12mo`, `all`, and the rest) or dates, a comparison, and filters such as `channel:is:Organic Search` or `page:contains:/blog`. Assistants pick these up from the tool descriptions, so you just ask.

Some things to try:

- "How did last month compare with the month before, and what changed most?"
- "Which blog posts do people from Google read longest?"
- "Where do the visitors who buy come from?"
- "Did anything unusual happen this week?"

## Scripts

The same token works with the [HTTP API](/docs/api/), for your own scripts and dashboards:

```bash
curl "https://example.com/runlight/api/stats?period=7d" -H "Authorization: Bearer rl_..."
```
