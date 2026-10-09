defmodule Runlight.Time do
  @moduledoc false
  # Internal. Dates in a site's timezone (the SDK's time.ts). Ranges are
  # computed here as epoch milliseconds so the database only ever compares
  # integers. A range is `%{from, to, from_date, to_date, interval}`: `from`
  # inclusive, `to` exclusive, and the first and last local dates covered,
  # YYYY-MM-DD, both inclusive. A bucket is `%{start, end}`.

  alias Runlight.JS
  alias Runlight.Zone

  @periods ~w(today yesterday 7d 30d 90d month last_month year 12mo all)
  @max_buckets 1000
  # A month of hours. Longer hourly ranges are cut off rather than refused.
  @max_hours 744

  def periods, do: @periods

  @doc "Whether `Intl.DateTimeFormat` takes the name as a timeZone."
  @spec timezone?(term()) :: boolean()
  def timezone?(value), do: is_binary(value) and Zone.find(value) != nil

  defp zone!(timezone) do
    Zone.find(timezone) || raise ArgumentError, "Invalid time zone specified: #{timezone}"
  end

  @doc false
  # Year, month, day, hour, minute, and second of an instant in a zone, as Intl formats them.
  def parts(ts, timezone), do: Zone.wall_at(Integer.floor_div(ts, 1000), zone!(timezone))

  # Milliseconds the zone is ahead of UTC at an instant.
  defp offset(ts, timezone) do
    {y, mo, d, h, mi, s} = parts(ts, timezone)
    JS.date_utc(y, mo - 1, d, h, mi, s) - (ts - rem(ts, 1000))
  end

  defp split(date) do
    [y, m, d] = date |> String.split("-") |> Enum.map(&String.to_integer/1)
    {y, m, d}
  end

  @doc "The instant a local date (and hour) begins in a zone."
  @spec start_of(String.t(), String.t(), integer()) :: integer()
  def start_of(date, timezone, hour \\ 0) do
    {y, m, d} = split(date)
    guess = JS.date_utc(y, m - 1, d, hour)
    first = guess - offset(guess, timezone)
    at = guess - offset(first, timezone)
    # Where clocks jump forward at that time (midnight in Santiago, Havana, and the Azores), it never
    # happens, and the sum above lands before it; the day then begins when the clocks land, at most a
    # few quarter hours on.
    Enum.reduce_while(1..8, at, fn _, at ->
      {ly, lm, ld, lh, _, _} = parts(at, timezone)
      if JS.date_utc(ly, lm - 1, ld, lh) >= guess, do: {:halt, at}, else: {:cont, at + 15 * 60_000}
    end)
  end

  @doc "The local date of an instant, YYYY-MM-DD."
  @spec local_date(integer(), String.t()) :: String.t()
  def local_date(ts, timezone) do
    {y, m, d, _, _, _} = parts(ts, timezone)
    "#{JS.pad(y, 4)}-#{JS.pad(m, 2)}-#{JS.pad(d, 2)}"
  end

  @spec add_days(String.t(), integer()) :: String.t()
  def add_days(date, days) do
    {y, m, d} = split(date)
    JS.iso_day(JS.date_utc(y, m - 1, d + days))
  end

  @spec add_months(String.t(), integer()) :: String.t()
  def add_months(date, months) do
    {y, m, _} = split(date)
    JS.iso_day(JS.date_utc(y, m - 1 + months, 1))
  end

  @doc "A date YYYY-MM-DD that exists, from 1900 to 9998."
  @spec date?(term()) :: boolean()
  def date?(value) when is_binary(value) do
    # Years from 1900 to 9998, so the day after any date is a date too.
    if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, value) and value >= "1900" and value < "9999" do
      {y, m, d} = split(value)
      m in 1..12 and d >= 1 and d <= JS.days_in_month(y, m)
    else
      false
    end
  end

  def date?(_), do: false

  defp days_between(from, to) do
    {fy, fm, fd} = split(from)
    {ty, tm, td} = split(to)
    JS.round((JS.date_utc(ty, tm - 1, td) - JS.date_utc(fy, fm - 1, fd)) / 86_400_000)
  end

  defp default_interval(from_date, to_date) do
    days = days_between(from_date, to_date)

    cond do
      days < 1 -> "hour"
      days <= 92 -> "day"
      true -> "month"
    end
  end

  @doc """
  A named period or custom dates as a range in the site's timezone.
  `first_date` is the earliest local date with data, used by "all".
  """
  @spec resolve_range(map(), String.t(), integer(), String.t() | nil) :: map() | nil
  def resolve_range(input, timezone, now, first_date \\ nil) do
    today = local_date(now, timezone)
    from = input[:from]
    to = input[:to]

    dates =
      if JS.truthy?(from) or JS.truthy?(to) do
        if JS.truthy?(from) and JS.truthy?(to) and date?(from) and date?(to) and from <= to, do: {from, to}
      else
        case input[:period] || "30d" do
          "today" -> {today, today}
          "yesterday" -> {add_days(today, -1), add_days(today, -1)}
          "7d" -> {add_days(today, -6), today}
          "30d" -> {add_days(today, -29), today}
          "90d" -> {add_days(today, -89), today}
          "month" -> {String.slice(today, 0, 8) <> "01", today}
          "last_month" -> {add_months(today, -1), add_days(String.slice(today, 0, 8) <> "01", -1)}
          "year" -> {String.slice(today, 0, 4) <> "-01-01", today}
          "12mo" -> {add_months(today, -11), today}
          "all" -> {if(JS.truthy?(first_date) and first_date < today, do: first_date, else: today), today}
          _ -> nil
        end
      end

    case dates do
      nil ->
        nil

      {from_date, to_date} ->
        interval =
          if input[:interval] in ["hour", "day", "week", "month"],
            do: input[:interval],
            else: default_interval(from_date, to_date)

        %{
          from: start_of(from_date, timezone),
          to: start_of(add_days(to_date, 1), timezone),
          from_date: from_date,
          to_date: to_date,
          interval: interval
        }
    end
  end

  defp add_years(date, years) do
    {y, m, d} = split(date)
    shifted = JS.date_utc(y + years, m - 1, d)
    {sy, sm, _} = JS.civil_from_days(Integer.floor_div(shifted, 86_400_000))
    # Feb 29 in a year without one becomes Feb 28, not Mar 1.
    if sm != m, do: JS.iso_day(JS.date_utc(sy, sm - 1, 0)), else: JS.iso_day(shifted)
  end

  @doc """
  The range a period is compared with: the same number of days just before
  it, the same dates a year earlier, or custom dates. Nil for "off" or bad
  custom dates.
  """
  @spec compare_range(map(), String.t(), String.t(), map()) :: map() | nil
  def compare_range(range, mode, timezone, custom \\ %{}) do
    dates =
      case mode do
        "off" ->
          nil

        "year" ->
          {add_years(range.from_date, -1), add_years(range.to_date, -1)}

        "custom" ->
          from = custom[:from]
          to = custom[:to]
          if JS.truthy?(from) and JS.truthy?(to) and date?(from) and date?(to) and from <= to, do: {from, to}

        _ ->
          days = days_between(range.from_date, range.to_date) + 1
          {add_days(range.from_date, -days), add_days(range.from_date, -1)}
      end

    case dates do
      nil ->
        nil

      {from_date, to_date} ->
        %{
          from: start_of(from_date, timezone),
          to: start_of(add_days(to_date, 1), timezone),
          from_date: from_date,
          to_date: to_date,
          interval: range.interval
        }
    end
  end

  @doc "Chart buckets covering a range, each starting on a local boundary."
  @spec buckets(map(), String.t()) :: [map()]
  def buckets(range, timezone) do
    starts =
      if range.interval == "hour" do
        range.from
        |> Stream.iterate(&(&1 + 3_600_000))
        |> Stream.take_while(&(&1 < range.to))
        |> Enum.take(@max_hours)
      else
        date = range.from_date

        date =
          case range.interval do
            "week" ->
              {y, m, d} = split(date)
              weekday = rem(JS.utc_weekday(JS.date_utc(y, m - 1, d)) + 6, 7)
              add_days(date, -weekday)

            "month" ->
              String.slice(date, 0, 8) <> "01"

            _ ->
              date
          end

        step = fn date ->
          case range.interval do
            "day" -> add_days(date, 1)
            "week" -> add_days(date, 7)
            _ -> add_months(date, 1)
          end
        end

        date
        |> Stream.iterate(step)
        |> Stream.take_while(&(&1 <= range.to_date))
        |> Enum.take(@max_buckets)
        |> Enum.map(&start_of(&1, timezone))
      end

    nexts = tl(starts ++ [nil])

    Enum.zip_with(starts, nexts, fn start, next ->
      %{start: max(start, range.from), end: min(next || range.to, range.to)}
    end)
  end

  @doc "The local weekday (Monday is 0) and hour of an instant."
  @spec local_weekday_hour(integer(), String.t()) :: {0..6, 0..23}
  def local_weekday_hour(ts, timezone) do
    {y, m, d, h, _, _} = parts(ts, timezone)
    {rem(JS.utc_weekday(JS.date_utc(y, m - 1, d)) + 6, 7), h}
  end
end
