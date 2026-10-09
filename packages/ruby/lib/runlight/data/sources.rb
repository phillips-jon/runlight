# frozen_string_literal: true

module Runlight
  module Data
    # Known traffic sources. `hosts` match a referrer host or any subdomain of
    # it; `aliases` match a lowercased utm_source, ref or source parameter.
    # Kept as data so every implementation reads the same list.
    #
    # A source is a Hash {"name", "kind" ("search", "social", "ai", "email", or "other"), "hosts", "aliases"}.
    module Sources
      SOURCES = [
        # AI assistants
        { "name" => "ChatGPT", "kind" => "ai", "hosts" => ["chatgpt.com", "chat.openai.com", "openai.com"], "aliases" => ["chatgpt", "chatgpt.com", "openai"] },
        { "name" => "Claude", "kind" => "ai", "hosts" => ["claude.ai"], "aliases" => ["claude", "claude.ai", "anthropic"] },
        { "name" => "Perplexity", "kind" => "ai", "hosts" => ["perplexity.ai"], "aliases" => ["perplexity", "perplexity.ai"] },
        { "name" => "Gemini", "kind" => "ai", "hosts" => ["gemini.google.com", "bard.google.com"], "aliases" => ["gemini", "gemini.google.com", "bard"] },
        { "name" => "Copilot", "kind" => "ai", "hosts" => ["copilot.microsoft.com", "copilot.cloud.microsoft"], "aliases" => ["copilot", "copilot.microsoft.com"] },
        { "name" => "Meta AI", "kind" => "ai", "hosts" => ["meta.ai"], "aliases" => ["meta.ai", "metaai"] },
        { "name" => "Grok", "kind" => "ai", "hosts" => ["grok.com", "x.ai"], "aliases" => ["grok", "grok.com"] },
        { "name" => "DeepSeek", "kind" => "ai", "hosts" => ["chat.deepseek.com", "deepseek.com"], "aliases" => ["deepseek"] },
        { "name" => "Mistral", "kind" => "ai", "hosts" => ["chat.mistral.ai", "mistral.ai"], "aliases" => ["mistral", "lechat"] },
        { "name" => "You.com", "kind" => "ai", "hosts" => ["you.com"], "aliases" => ["you.com"] },
        { "name" => "Phind", "kind" => "ai", "hosts" => ["phind.com"], "aliases" => ["phind"] },

        # Search
        { "name" => "Google", "kind" => "search", "hosts" => ["com.google.android.googlequicksearchbox", "google.com", "google.co.uk", "google.ca", "google.com.au", "google.de", "google.fr", "google.es", "google.it", "google.nl", "google.co.in", "google.co.jp", "google.com.br", "google.com.mx", "google.ie", "google.co.nz", "google.ch", "google.at", "google.be", "google.se", "google.dk", "google.no", "google.fi", "google.pl", "google.pt"], "aliases" => ["google"] },
        { "name" => "Bing", "kind" => "search", "hosts" => ["bing.com"], "aliases" => ["bing"] },
        { "name" => "DuckDuckGo", "kind" => "search", "hosts" => ["duckduckgo.com"], "aliases" => ["duckduckgo", "ddg"] },
        { "name" => "Yahoo", "kind" => "search", "hosts" => ["yahoo.com", "search.yahoo.com"], "aliases" => ["yahoo"] },
        { "name" => "Yandex", "kind" => "search", "hosts" => ["yandex.ru", "yandex.com"], "aliases" => ["yandex"] },
        { "name" => "Baidu", "kind" => "search", "hosts" => ["baidu.com"], "aliases" => ["baidu"] },
        { "name" => "Ecosia", "kind" => "search", "hosts" => ["ecosia.org"], "aliases" => ["ecosia"] },
        { "name" => "Brave Search", "kind" => "search", "hosts" => ["search.brave.com"], "aliases" => ["brave"] },
        { "name" => "Startpage", "kind" => "search", "hosts" => ["startpage.com"], "aliases" => ["startpage"] },
        { "name" => "Qwant", "kind" => "search", "hosts" => ["qwant.com"], "aliases" => ["qwant"] },
        { "name" => "Kagi", "kind" => "search", "hosts" => ["kagi.com"], "aliases" => ["kagi"] },
        { "name" => "Naver", "kind" => "search", "hosts" => ["naver.com"], "aliases" => ["naver"] },

        # Social
        { "name" => "Facebook", "kind" => "social", "hosts" => ["facebook.com", "fb.com", "m.facebook.com", "l.facebook.com", "lm.facebook.com"], "aliases" => ["facebook", "fb"] },
        { "name" => "Instagram", "kind" => "social", "hosts" => ["instagram.com", "l.instagram.com"], "aliases" => ["instagram", "ig"] },
        { "name" => "X", "kind" => "social", "hosts" => ["x.com", "twitter.com", "t.co"], "aliases" => ["twitter", "x", "x.com"] },
        { "name" => "LinkedIn", "kind" => "social", "hosts" => ["linkedin.com", "lnkd.in", "com.linkedin.android"], "aliases" => ["linkedin"] },
        { "name" => "Reddit", "kind" => "social", "hosts" => ["reddit.com", "old.reddit.com", "out.reddit.com", "com.reddit.frontpage"], "aliases" => ["reddit"] },
        { "name" => "Hacker News", "kind" => "social", "hosts" => ["news.ycombinator.com"], "aliases" => ["hackernews", "hn", "news.ycombinator.com"] },
        { "name" => "YouTube", "kind" => "social", "hosts" => ["youtube.com", "youtu.be", "m.youtube.com"], "aliases" => ["youtube", "yt"] },
        { "name" => "Pinterest", "kind" => "social", "hosts" => ["pinterest.com", "pin.it"], "aliases" => ["pinterest"] },
        { "name" => "TikTok", "kind" => "social", "hosts" => ["tiktok.com"], "aliases" => ["tiktok"] },
        { "name" => "Threads", "kind" => "social", "hosts" => ["threads.net", "threads.com"], "aliases" => ["threads"] },
        { "name" => "Bluesky", "kind" => "social", "hosts" => ["bsky.app"], "aliases" => ["bluesky", "bsky"] },
        { "name" => "Mastodon", "kind" => "social", "hosts" => ["mastodon.social", "mastodon.online", "fosstodon.org", "hachyderm.io"], "aliases" => ["mastodon"] },
        { "name" => "Product Hunt", "kind" => "social", "hosts" => ["producthunt.com"], "aliases" => ["producthunt"] },
        { "name" => "GitHub", "kind" => "social", "hosts" => ["github.com"], "aliases" => ["github"] },
        { "name" => "Dev.to", "kind" => "social", "hosts" => ["dev.to"], "aliases" => ["devto", "dev.to"] },
        { "name" => "Medium", "kind" => "social", "hosts" => ["medium.com"], "aliases" => ["medium"] },
        { "name" => "Substack", "kind" => "social", "hosts" => ["substack.com"], "aliases" => ["substack"] },
        { "name" => "Discord", "kind" => "social", "hosts" => ["discord.com", "discordapp.com"], "aliases" => ["discord"] },
        { "name" => "Slack", "kind" => "social", "hosts" => ["slack.com", "com.slack"], "aliases" => ["slack"] },
        { "name" => "Telegram", "kind" => "social", "hosts" => ["t.me", "telegram.org"], "aliases" => ["telegram"] },
        { "name" => "WhatsApp", "kind" => "social", "hosts" => ["whatsapp.com", "wa.me"], "aliases" => ["whatsapp"] },

        # Email
        { "name" => "Gmail", "kind" => "email", "hosts" => ["mail.google.com", "com.google.android.gm"], "aliases" => ["gmail"] },
        { "name" => "Kit", "kind" => "email", "hosts" => ["kit.com", "convertkit.com", "ck.page", "kit-mail.com"], "aliases" => ["kit", "convertkit"] },
        { "name" => "Outlook", "kind" => "email", "hosts" => ["outlook.live.com", "outlook.office.com", "outlook.office365.com"], "aliases" => ["outlook"] },
        { "name" => "Yahoo Mail", "kind" => "email", "hosts" => ["mail.yahoo.com"], "aliases" => ["yahoomail"] },
        { "name" => "Fastmail", "kind" => "email", "hosts" => ["app.fastmail.com", "fastmail.com"], "aliases" => ["fastmail"] },
        { "name" => "Proton Mail", "kind" => "email", "hosts" => ["mail.proton.me"], "aliases" => ["protonmail"] },
        { "name" => "Newsletter", "kind" => "email", "hosts" => [], "aliases" => ["newsletter", "email", "e-mail", "mailchimp", "kit", "convertkit", "beehiiv", "buttondown"] },
      ].freeze

      # Hosts known by their shape rather than their name: email services' click
      # trackers (Kit sends clicks through numbered hosts like
      # 15a992bb.click.convertkit-mail4.com) and webmail (mail.aol.com,
      # mail01.orange.fr, webmail.example.net).
      SOURCE_PATTERNS = [
        { "pattern" => /(\A|\.)convertkit-mail\d*\.com\z|(\A|\.)kit-mail\d*\.com\z/, "name" => "Kit", "kind" => "email" },
        { "pattern" => /(\A|\.)(list-manage|mailchi)\.(com|mp)\z/, "name" => "Mailchimp", "kind" => "email" },
        { "pattern" => /(\A|\.)beehiiv\.com\z/, "name" => "beehiiv", "kind" => "email" },
        { "pattern" => /(\A|\.)substack\.com\z/, "name" => "Substack", "kind" => "email" },
        { "pattern" => /\A(web)?mail\d*\.|(\A|\.)webmail\./, "name" => nil, "kind" => "email" },
      ].freeze
    end
  end
end
