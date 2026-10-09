defmodule Runlight.Reports do
  @moduledoc false
  # Internal. Email reports: which period is due, and one site's report for a
  # period in a language, as HTML and text (the SDK's reports.ts), byte for
  # byte what the TypeScript SDK sends.

  alias Runlight.Intl
  alias Runlight.JS
  alias Runlight.Messages
  alias Runlight.Store
  alias Runlight.Time

  @doc """
  The last complete week (Monday to Sunday) or month before `now`, in a
  timezone: `%{key, from_date, to_date, previous_from, previous_to, due_at}`.
  The key is w:<monday> or m:<yyyy-mm>, so each period is sent once, and a
  report goes out from 8am the day after the period ends.
  """
  @spec last_period(String.t(), integer(), String.t()) :: map()
  def last_period("monthly", now, timezone) do
    today = Time.local_date(now, timezone)
    first = String.slice(today, 0, 8) <> "01"
    from = Time.add_months(first, -1)

    %{
      key: "m:" <> String.slice(from, 0, 7),
      from_date: from,
      to_date: Time.add_days(first, -1),
      previous_from: Time.add_months(from, -1),
      previous_to: Time.add_days(from, -1),
      due_at: Time.start_of(first, timezone, 8)
    }
  end

  def last_period(_weekly, now, timezone) do
    today = Time.local_date(now, timezone)
    [y, m, d] = today |> String.split("-") |> Enum.map(&String.to_integer/1)
    weekday = rem(JS.utc_weekday(JS.date_utc(y, m - 1, d)) + 6, 7)
    monday = Time.add_days(today, -weekday)
    from = Time.add_days(monday, -7)

    %{
      key: "w:" <> from,
      from_date: from,
      to_date: Time.add_days(monday, -1),
      previous_from: Time.add_days(from, -7),
      previous_to: Time.add_days(from, -1),
      due_at: Time.start_of(monday, timezone, 8)
    }
  end

  defp esc(value), do: JS.escape_html(value)

  defp duration(ms) do
    seconds = JS.round(ms / 1000)

    cond do
      seconds < 60 ->
        "#{seconds}s"

      div(seconds, 60) < 60 ->
        "#{div(seconds, 60)}m #{JS.pad(rem(seconds, 60), 2)}s"

      true ->
        minutes = div(seconds, 60)
        "#{div(minutes, 60)}h #{JS.pad(rem(minutes, 60), 2)}m"
    end
  end

  @doc """
  One site's report for a period, in a language: `%{subject, html, text}`.
  `links` are absolute: the dashboard and the recipient's unsubscribe page.
  """
  @spec build_report(Runlight.t(), JS.Object.t(), String.t(), map(), String.t(), map()) :: map()
  def build_report(rl, site, frequency, period, lang, links) do
    code = Messages.code(lang)
    t = fn key, vars -> Messages.t(code, key, vars) end
    tn = fn key, n, vars -> Messages.tn(code, key, n, vars) end
    tz = site["timezone"]

    range = fn from, to ->
      %{site: site["id"], from: Time.start_of(from, tz), to: Time.start_of(Time.add_days(to, 1), tz), filters: []}
    end

    query = range.(period.from_date, period.to_date)
    before = range.(period.previous_from, period.previous_to)
    store = rl.store
    now = Store.stats(store, query)
    prev = Store.stats(store, before)
    pages = Store.breakdown(store, query, "page", 5, 0)
    sources = Store.breakdown(store, query, "source", 5, 0)
    countries = Store.breakdown(store, query, "country", 5, 0)
    goals = Store.goals(store, site["id"])
    totals = Store.goal_totals_all(store, query, goals)
    goal_rows = Enum.map(goals, &{&1, totals[&1["id"]]})

    number = fn n -> Intl.number(code, n) end
    percent = fn n -> Intl.percent(code, n) end
    decimal = fn n -> Intl.number(code, n, 1, 1) end
    money = fn n, currency -> Intl.currency(code, n, currency, if(JS.integer?(n), do: 0, else: 2)) end
    month_name = fn d -> Intl.month_year(code, d) end

    # Each end formatted on its own, joined in the reader's language (never with a dash).
    span = fn from, to ->
      same_year = String.slice(from, 0, 4) == String.slice(to, 0, 4)
      t.("email.range", %{"from" => Intl.short_day(code, from, not same_year), "to" => Intl.short_day(code, to, true)})
    end

    monthly = frequency == "monthly"

    whenever =
      if monthly,
        do: t.("email.when.month", %{"month" => month_name.(period.from_date)}),
        else: t.("email.when.week", %{})

    against = if monthly, do: month_name.(period.previous_from), else: t.("email.before.week", %{})
    who = tn.("headline.who", now["visitors"], %{"n" => number.(now["visitors"])})
    verb = tn.("headline.visited", now["visitors"], %{})
    change = if prev["visitors"] != 0, do: (now["visitors"] - prev["visitors"]) / prev["visitors"]

    headline =
      cond do
        prev["visitors"] == 0 and now["visitors"] > 0 ->
          t.("headline.fromNone", %{"who" => who, "verb" => verb, "when" => whenever, "against" => against})

        change == nil ->
          t.("headline.plain", %{"who" => who, "verb" => verb, "when" => whenever})

        true ->
          key =
            if abs(change) < 0.005, do: "headline.same", else: if(change > 0, do: "headline.up", else: "headline.down")

          t.(key, %{
            "who" => who,
            "verb" => verb,
            "when" => whenever,
            "against" => against,
            "change" =>
              t.(if(change > 0, do: "headline.more", else: "headline.fewer"), %{"pct" => abs(JS.round(change * 100))})
          })
      end

    subject =
      t.(if(monthly, do: "email.subject.month", else: "email.subject.week"), %{
        "site" => site["name"],
        "who" => who,
        "month" => month_name.(period.from_date)
      })

    dates = span.(period.from_date, period.to_date)

    metrics = [
      {"visitors", number, false},
      {"visits", number, false},
      {"pageviews", number, false},
      {"viewsPerVisit", decimal, false},
      {"bounceRate", percent, true},
      {"visitDuration", &duration/1, false}
    ]

    delta = fn key, lower_is_better ->
      b = prev[key]

      if b == 0 do
        {"", "#6b7280", "flat"}
      else
        c = (now[key] - b) / b

        if abs(c) < 0.005 do
          {"0%", "#6b7280", "flat"}
        else
          good = if lower_is_better, do: c < 0, else: c > 0

          {"#{if c > 0, do: "↑", else: "↓"} #{percent.(abs(c))}", if(good, do: "#15803d", else: "#b91c1c"),
           if(good, do: "up", else: "down")}
        end
      end
    end

    lists = [
      {t.("email.pages", %{}), Enum.map(pages, &{JS.or_else(&1["value"], "/"), number.(&1["visitors"])})},
      {t.("email.sources", %{}),
       Enum.map(sources, &{JS.or_else(&1["value"], t.("goals.unknown", %{})), number.(&1["visitors"])})},
      {t.("email.countries", %{}), Enum.map(countries, &{Intl.region(code, &1["value"]), number.(&1["visitors"])})}
    ]

    lists =
      if goal_rows != [] do
        rows =
          goal_rows
          |> Enum.sort_by(fn {_, totals} -> -totals["conversions"] end)
          |> Enum.map(fn {goal, totals} ->
            label =
              if goal["valueMode"] != "none" and JS.truthy?(totals["revenue"]),
                do: "#{goal["name"]} (#{money.(totals["revenue"], goal["currency"])})",
                else: goal["name"]

            {label, number.(totals["conversions"])}
          end)

        lists ++ [{t.("email.conversions", %{}), rows}]
      else
        lists
      end

    font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"

    cell = fn {key, format, lower} ->
      {text, color, tone} = delta.(key, lower)

      """
      <td width="33%" class="rl-line" style="padding:12px 14px;border:1px solid #e5e7eb;border-radius:10px;vertical-align:top">
      <div class="rl-muted" style="font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">#{esc(t.("metric.#{key}", %{}))}</div>
      <div class="rl-ink" style="font-size:24px;font-weight:600;color:#111827;margin-top:4px">#{esc(format.(now[key]))}</div>
      <div class="rl-#{tone}" style="font-size:12px;color:#{color};margin-top:2px;min-height:16px">#{esc(text)}</div></td>\
      """
    end

    table = fn {title, rows} ->
      body =
        if rows != [] do
          Enum.map_join(rows, "", fn {a, b} ->
            ~s(<tr><td class="rl-row rl-body-text" style="padding:7px 0;border-top:1px solid #f0f0f0;color:#374151;word-break:break-all">#{esc(a)}</td><td align="right" class="rl-row rl-ink" style="padding:7px 0 7px 12px;border-top:1px solid #f0f0f0;color:#111827;font-weight:600;white-space:nowrap">#{esc(b)}</td></tr>)
          end)
        else
          ~s(<tr><td class="rl-muted" style="padding:7px 0;color:#6b7280">#{esc(t.("panel.empty", %{}))}</td></tr>)
        end

      """
      <h3 class="rl-ink" style="font-size:14px;color:#111827;margin:28px 0 8px">#{esc(title)}</h3>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:14px">#{body}</table>\
      """
    end

    # Where the dashboard lives, without the scheme or the site query.
    where =
      case Runlight.Url.parse(links.dashboard) do
        nil -> links.dashboard
        u -> "#{Runlight.Url.host(u)}#{String.replace(u.pathname, ~r/\/$/, "")}"
      end

    at = t.("email.at", %{"where" => where})

    # The Runlight mark in table cells: mail apps block SVG and most inline images.
    mark = """
    <table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse"><tr>
    <td class="rl-mark" width="24" height="24" align="center" style="width:24px;height:24px;background:#111827;border-radius:7px;color:#ffffff;font-size:15px;font-weight:700;line-height:24px;text-align:center;font-family:#{font}">R</td>
    <td class="rl-ink" style="padding-left:8px;font-size:15px;font-weight:700;color:#111827;font-family:#{font}">Runlight</td></tr></table>\
    """

    footer =
      t.("email.footer", %{
        "frequency" => t.(if(monthly, do: "email.monthly", else: "email.weekly"), %{}),
        "site" => site["name"]
      })

    at_link =
      String.replace(
        esc(t.("email.at", %{"where" => <<0>>})),
        <<0>>,
        ~s(<a href="#{esc(links.dashboard)}" class="rl-muted" style="color:#6b7280">#{esc(where)}</a>),
        global: false
      )

    {first3, rest3} = Enum.split(metrics, 3)

    html = """
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
    <td align="right" class="rl-muted" style="vertical-align:middle;font-size:12px;color:#6b7280">#{at_link}</td>
    </tr></table>
    <div class="rl-muted" style="font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">#{esc(site["name"])} · #{esc(dates)}</div>
    <h1 class="rl-ink" style="font-size:24px;line-height:1.3;color:#111827;margin:10px 0 24px;font-weight:600">#{esc(headline)}</h1>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="6" style="border-collapse:separate;margin:0 -6px">
    <tr>#{Enum.map_join(first3, "", cell)}</tr><tr>#{Enum.map_join(rest3, "", cell)}</tr></table>
    #{Enum.map_join(lists, "", table)}
    <p style="margin:32px 0 0"><a href="#{esc(links.dashboard)}" class="rl-button" style="display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:11px 18px;border-radius:8px;font-size:14px;font-weight:600">#{esc(t.("email.open", %{}))}</a></p>
    </td></tr></table>
    <p class="rl-foot" style="max-width:600px;font-size:12px;line-height:1.5;color:#6b7280;margin:16px auto 0">#{esc(footer)} <a href="#{esc(links.unsubscribe)}" style="color:#6b7280">#{esc(t.("email.unsubscribe", %{}))}</a></p>
    </td></tr></table></body></html>\
    """

    # French sets a space before a colon, as its subject line does.
    colon = if code == "fr", do: " :", else: ":"

    text =
      Enum.join(
        ["Runlight · #{at}", "", "#{site["name"]} · #{dates}", "", headline, ""] ++
          Enum.map(metrics, fn {key, format, lower} ->
            {d, _, _} = delta.(key, lower)
            "#{t.("metric.#{key}", %{})}#{colon} #{format.(now[key])}#{if d != "", do: " (#{d})", else: ""}"
          end) ++
          Enum.flat_map(lists, fn {title, rows} ->
            ["", title] ++
              if(rows != [],
                do: Enum.map(rows, fn {a, b} -> "  #{a}#{colon} #{b}" end),
                else: ["  #{t.("panel.empty", %{})}"]
              )
          end) ++
          [
            "",
            "#{t.("email.open", %{})}#{colon} #{links.dashboard}",
            "",
            "#{footer} #{t.("email.unsubscribe", %{})}#{colon} #{links.unsubscribe}"
          ],
        "\n"
      )

    %{subject: subject, html: html, text: text}
  end
end
