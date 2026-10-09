# frozen_string_literal: true

require "date"

module Runlight
  # Email reports: the period each one covers, and the message itself, in the reader's language.
  #
  # A ReportPeriod is a Hash: "key" (w:<monday> or m:<yyyy-mm>, so each period is sent once), "fromDate",
  # "toDate", "previousFrom", "previousTo", and "dueAt" (reports go out from 8am the day after the period
  # ends, in the site's timezone).
  module Reports
    ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#39;" }.freeze
    private_constant :ESCAPES

    module_function

    # The last complete week (Monday to Sunday) or month before `now`, in a timezone.
    def last_period(frequency, now, timezone)
      today = Dates.local_date(now, timezone)
      if frequency == "monthly"
        first = "#{today[0, 8]}01"
        from_date = Dates.add_months(first, -1)
        return {
          "key" => "m:#{from_date[0, 7]}",
          "fromDate" => from_date,
          "toDate" => Dates.add_days(first, -1),
          "previousFrom" => Dates.add_months(from_date, -1),
          "previousTo" => Dates.add_days(from_date, -1),
          "dueAt" => Dates.start_of(first, timezone, 8),
        }
      end
      weekday = Date.iso8601(today).cwday - 1
      monday = Dates.add_days(today, -weekday)
      from_date = Dates.add_days(monday, -7)
      {
        "key" => "w:#{from_date}",
        "fromDate" => from_date,
        "toDate" => Dates.add_days(monday, -1),
        "previousFrom" => Dates.add_days(from_date, -7),
        "previousTo" => Dates.add_days(from_date, -1),
        "dueAt" => Dates.start_of(monday, timezone, 8),
      }
    end

    # One site's report for a period, in a language. `links` are absolute: the
    # dashboard ("dashboard") and the recipient's unsubscribe page ("unsubscribe").
    # Gives { "subject", "html", "text" }.
    def build_report(runlight, site, frequency, period, lang, links)
      translator = Messages.translator(lang)
      t = translator["t"]
      tn = translator["tn"]
      code = translator["lang"]
      tz = site["timezone"]
      range = lambda do |from, to|
        { "site" => site["id"], "from" => Dates.start_of(from, tz), "to" => Dates.start_of(Dates.add_days(to, 1), tz), "filters" => [] }
      end
      query = range.call(period["fromDate"], period["toDate"])
      before = range.call(period["previousFrom"], period["previousTo"])
      store = runlight.store
      now = store.stats(query)
      prev = store.stats(before)
      pages = store.breakdown(query, "page", 5, 0)
      sources = store.breakdown(query, "source", 5, 0)
      countries = store.breakdown(query, "country", 5, 0)
      goals = store.goals(site["id"])
      totals = store.goal_totals_all(query, goals)

      number = ->(n) { Intl.number(code, n) }
      percent = ->(n) { Intl.percent(code, n) }
      decimal = ->(n) { Intl.number(code, n, 1, 1) }
      money = ->(n, currency) { Intl.currency(code, n, currency, n.is_a?(Integer) || n.floor == n ? 0 : 2) }
      month_name = ->(d) { Intl.month_year(code, d) }
      # Each end formatted on its own, joined in the reader's language (never with a dash).
      span = lambda do |from, to|
        same_year = from[0, 4] == to[0, 4]
        t.call("email.range", { "from" => Intl.short_day(code, from, !same_year), "to" => Intl.short_day(code, to, true) })
      end
      country = ->(code2) { Intl.region(code, code2) }

      monthly = frequency == "monthly"
      when_text = monthly ? t.call("email.when.month", { "month" => month_name.call(period["fromDate"]) }) : t.call("email.when.week")
      against = monthly ? month_name.call(period["previousFrom"]) : t.call("email.before.week")
      who = tn.call("headline.who", now["visitors"], { "n" => number.call(now["visitors"]) })
      verb = tn.call("headline.visited", now["visitors"])
      change = Js.truthy?(prev["visitors"]) ? (now["visitors"] - prev["visitors"]).fdiv(prev["visitors"]) : nil
      headline = if prev["visitors"].zero? && now["visitors"].positive?
                   t.call("headline.fromNone", { "who" => who, "verb" => verb, "when" => when_text, "against" => against })
                 elsif change.nil?
                   t.call("headline.plain", { "who" => who, "verb" => verb, "when" => when_text })
                 else
                   key = if change.abs < 0.005 then "headline.same"
                         elsif change.positive? then "headline.up"
                         else "headline.down"
                         end
                   t.call(key, {
                     "who" => who,
                     "verb" => verb,
                     "when" => when_text,
                     "against" => against,
                     "change" => t.call(change.positive? ? "headline.more" : "headline.fewer", { "pct" => Js.round(change * 100).abs.to_i }),
                   })
                 end
      subject = t.call(monthly ? "email.subject.month" : "email.subject.week",
                       { "site" => site["name"], "who" => who, "month" => month_name.call(period["fromDate"]) })
      dates = span.call(period["fromDate"], period["toDate"])

      metrics = [
        { "key" => "visitors", "format" => number, "lowerIsBetter" => false },
        { "key" => "visits", "format" => number, "lowerIsBetter" => false },
        { "key" => "pageviews", "format" => number, "lowerIsBetter" => false },
        { "key" => "viewsPerVisit", "format" => decimal, "lowerIsBetter" => false },
        { "key" => "bounceRate", "format" => percent, "lowerIsBetter" => true },
        { "key" => "visitDuration", "format" => method(:duration), "lowerIsBetter" => false },
      ]
      delta = lambda do |key, lower_is_better|
        b = prev[key]
        next { "text" => "", "color" => "#6b7280", "tone" => "flat" } unless Js.truthy?(b)

        c = (now[key] - b).fdiv(b)
        next { "text" => "0%", "color" => "#6b7280", "tone" => "flat" } if c.abs < 0.005

        good = lower_is_better ? c.negative? : c.positive?
        { "text" => "#{c.positive? ? "↑" : "↓"} #{percent.call(c.abs)}", "color" => good ? "#15803d" : "#b91c1c", "tone" => good ? "up" : "down" }
      end

      lists = [
        { "title" => t.call("email.pages"),
          "rows" => pages.map { |r| [Js.truthy?(r["value"]) ? Js.string(r["value"]) : "/", number.call(r["visitors"])] } },
        { "title" => t.call("email.sources"),
          "rows" => sources.map { |r| [Js.truthy?(r["value"]) ? Js.string(r["value"]) : t.call("goals.unknown"), number.call(r["visitors"])] } },
        { "title" => t.call("email.countries"),
          "rows" => countries.map { |r| [country.call(Js.string(r["value"])), number.call(r["visitors"])] } },
      ]
      unless goals.empty?
        goal_rows = goals.map { |g| { "goal" => g, "totals" => totals[g["id"]] } }
        goal_rows = goal_rows.each_with_index.sort_by { |row, i| [-row["totals"]["conversions"], i] }.map(&:first)
        lists << {
          "title" => t.call("email.conversions"),
          "rows" => goal_rows.map do |row|
            goal = row["goal"]
            revenue = row["totals"]["revenue"]
            label = if goal["valueMode"] != "none" && Js.truthy?(revenue)
                      "#{goal["name"]} (#{money.call(revenue, goal["currency"])})"
                    else
                      goal["name"]
                    end
            [label, number.call(row["totals"]["conversions"])]
          end,
        }
      end

      font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"
      cell = lambda do |m|
        d = delta.call(m["key"], m["lowerIsBetter"])
        label = esc(t.call("metric.#{m["key"]}"))
        value = esc(m["format"].call(now[m["key"]]))
        text = esc(d["text"])
        <<~HTML.chomp
          <td width="33%" class="rl-line" style="padding:12px 14px;border:1px solid #e5e7eb;border-radius:10px;vertical-align:top">
          <div class="rl-muted" style="font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">#{label}</div>
          <div class="rl-ink" style="font-size:24px;font-weight:600;color:#111827;margin-top:4px">#{value}</div>
          <div class="rl-#{d["tone"]}" style="font-size:12px;color:#{d["color"]};margin-top:2px;min-height:16px">#{text}</div></td>
        HTML
      end
      table = lambda do |l|
        title = esc(l["title"])
        rows = if l["rows"].empty?
                 "<tr><td class=\"rl-muted\" style=\"padding:7px 0;color:#6b7280\">#{esc(t.call("panel.empty"))}</td></tr>"
               else
                 l["rows"].map do |r|
                   "<tr><td class=\"rl-row rl-body-text\" style=\"padding:7px 0;border-top:1px solid #f0f0f0;color:#374151;word-break:break-all\">#{esc(r[0])}</td>" \
                     "<td align=\"right\" class=\"rl-row rl-ink\" style=\"padding:7px 0 7px 12px;border-top:1px solid #f0f0f0;color:#111827;font-weight:600;white-space:nowrap\">#{esc(r[1])}</td></tr>"
                 end.join
               end
        <<~HTML.chomp
          <h3 class="rl-ink" style="font-size:14px;color:#111827;margin:28px 0 8px">#{title}</h3>
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:14px">#{rows}</table>
        HTML
      end

      # Where the dashboard lives, without the scheme or the site query, so a reader
      # with several installs can tell which one sent this.
      u = Http::Url.parse(links["dashboard"])
      where = u.nil? ? links["dashboard"] : u.host + u.pathname.sub(%r{/\z}, "")
      at = t.call("email.at", { "where" => where })
      # The Runlight mark in table cells: mail apps block SVG and most inline images.
      mark = <<~HTML.chomp
        <table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse"><tr>
        <td class="rl-mark" width="24" height="24" align="center" style="width:24px;height:24px;background:#111827;border-radius:7px;color:#ffffff;font-size:15px;font-weight:700;line-height:24px;text-align:center;font-family:#{font}">R</td>
        <td class="rl-ink" style="padding-left:8px;font-size:15px;font-weight:700;color:#111827;font-family:#{font}">Runlight</td></tr></table>
      HTML

      footer = t.call("email.footer", { "frequency" => t.call(monthly ? "email.monthly" : "email.weekly"), "site" => site["name"] })
      at_line = esc(t.call("email.at", { "where" => "\0" }))
      hole = at_line.index("\0")
      unless hole.nil?
        at_line = at_line[0...hole] +
                  "<a href=\"#{esc(links["dashboard"])}\" class=\"rl-muted\" style=\"color:#6b7280\">#{esc(where)}</a>" +
                  at_line[(hole + 1)..]
      end
      cells1 = metrics[0, 3].map { |m| cell.call(m) }.join
      cells2 = metrics[3..].map { |m| cell.call(m) }.join
      tables = lists.map { |l| table.call(l) }.join
      html = <<~HTML.chomp
        <!doctype html><html lang="#{code}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"><title>#{esc(subject)}</title>
        <style>
        @media (prefers-color-scheme: dark) {
          .rl-page { background: #09090b !important; }
          .rl-card { background: #141417 !important; border-color: #27272a !important; }
          .rl-line { border-color: #27272a !important; }
          .rl-row { border-top-color: #1f1f23 !important; }
          .rl-ink { color: #ffffff !important; }
          .rl-body-text { color: #d4d4d8 !important; }
          .rl-muted, .rl-flat { color: #a1a1aa !important; }
          .rl-up { color: #4ade80 !important; }
          .rl-down { color: #f87171 !important; }
          .rl-button { background: #ffffff !important; color: #000000 !important; }
          .rl-mark { background: #ffffff !important; color: #000000 !important; }
          .rl-foot, .rl-foot a { color: #a1a1aa !important; }
        }
        </style></head>
        <body class="rl-page" style="margin:0;padding:0;background:#f4f4f5;font-family:#{font}">
        <div style="display:none;max-height:0;overflow:hidden">#{esc(headline)}</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-page" style="background:#f4f4f5"><tr><td align="center" style="padding:32px 16px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-card" style="max-width:600px;background:#ffffff;border-radius:14px;border:1px solid #e5e7eb"><tr><td style="padding:32px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:0 0 24px"><tr>
        <td style="vertical-align:middle">#{mark}</td>
        <td align="right" class="rl-muted" style="vertical-align:middle;font-size:12px;color:#6b7280">#{at_line}</td>
        </tr></table>
        <div class="rl-muted" style="font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">#{esc(site["name"])} · #{esc(dates)}</div>
        <h1 class="rl-ink" style="font-size:24px;line-height:1.3;color:#111827;margin:10px 0 24px;font-weight:600">#{esc(headline)}</h1>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="6" style="border-collapse:separate;margin:0 -6px">
        <tr>#{cells1}</tr><tr>#{cells2}</tr></table>
        #{tables}
        <p style="margin:32px 0 0"><a href="#{esc(links["dashboard"])}" class="rl-button" style="display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:11px 18px;border-radius:8px;font-size:14px;font-weight:600">#{esc(t.call("email.open"))}</a></p>
        </td></tr></table>
        <p class="rl-foot" style="max-width:600px;font-size:12px;line-height:1.5;color:#6b7280;margin:16px auto 0">#{esc(footer)} <a href="#{esc(links["unsubscribe"])}" style="color:#6b7280">#{esc(t.call("email.unsubscribe"))}</a></p>
        </td></tr></table></body></html>
      HTML

      # French sets a space before a colon, as its subject line does.
      colon = code == "fr" ? " :" : ":"
      lines = ["Runlight · #{at}", "", "#{site["name"]} · #{dates}", "", headline, ""]
      metrics.each do |m|
        d = delta.call(m["key"], m["lowerIsBetter"])["text"]
        lines << "#{t.call("metric.#{m["key"]}")}#{colon} #{m["format"].call(now[m["key"]])}#{d == "" ? "" : " (#{d})"}"
      end
      lists.each do |l|
        lines << ""
        lines << l["title"]
        if l["rows"].empty?
          lines << "  #{t.call("panel.empty")}"
        else
          l["rows"].each { |a, b| lines << "  #{a}#{colon} #{b}" }
        end
      end
      lines.push("", "#{t.call("email.open")}#{colon} #{links["dashboard"]}", "",
                 "#{footer} #{t.call("email.unsubscribe")}#{colon} #{links["unsubscribe"]}")

      { "subject" => subject, "html" => html, "text" => lines.join("\n") }
    end

    def esc(value)
      value.to_s.gsub(/[&<>"']/, ESCAPES)
    end

    def duration(ms)
      seconds = Js.round(ms / 1000.0).to_i
      return "#{seconds}s" if seconds < 60

      minutes = seconds / 60
      return "#{minutes}m #{(seconds % 60).to_s.rjust(2, "0")}s" if minutes < 60

      "#{minutes / 60}h #{(minutes % 60).to_s.rjust(2, "0")}m"
    end

    private_class_method :esc, :duration
  end
end
