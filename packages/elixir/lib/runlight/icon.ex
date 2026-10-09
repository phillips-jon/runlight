defmodule Runlight.Icon do
  @moduledoc false
  # Internal. A site's icon, for the dashboard header: the best icon its home
  # page links to, or /favicon.ico (the SDK's icon.ts). Fetched from the
  # site's own configured origin (never from request input), cached in the
  # instance's state for a day, or an hour when there was none.

  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.Safefetch
  alias Runlight.State
  alias Runlight.Url

  @timeout_ms 4000
  @max_bytes 256 * 1024
  @day 86_400_000

  defp attr(tag, name) do
    case Regex.run(~r/\b#{name}\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/i, tag) do
      nil -> ""
      match -> match |> Enum.drop(2) |> Enum.find("", &(&1 != "")) |> JS.trim()
    end
  end

  @doc "Icon URLs a page links to, best first: apple-touch-icon, then SVG and PNG icons, then any icon."
  @spec icon_links(String.t(), String.t()) :: [String.t()]
  def icon_links(html, base) do
    ~r/<link\b[^>]*>/i
    |> Regex.scan(html)
    |> Enum.flat_map(fn [tag] ->
      rel = tag |> attr("rel") |> JS.lower() |> String.split(~r/\s+/)
      href = attr(tag, "href")

      with true <- href != "" and ("icon" in rel or "apple-touch-icon" in rel),
           %Url{} = url <- Url.parse(href, base),
           text = Url.href(url),
           # Only https, which is all the fetch below takes.
           true <- String.starts_with?(text, "https://") do
        type = tag |> attr("type") |> JS.lower()

        score =
          cond do
            "apple-touch-icon" in rel -> 3
            String.contains?(type, "svg") or String.ends_with?(text, ".svg") -> 2
            String.contains?(type, "png") or String.ends_with?(text, ".png") -> 1
            true -> 0
          end

        [{text, score}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_, score} -> -score end)
    |> Enum.map(&elem(&1, 0))
  end

  # A GET of a public https address, with redirects followed only to public addresses too.
  defp get(rl, url, opts) do
    case Safefetch.public_fetch(
           rl,
           url,
           [timeout: @timeout_ms, redirects: 3, headers: [{"user-agent", "Runlight (+https://runlight.sh)"}]] ++ opts
         ) do
      {:ok, response} -> response
      _ -> nil
    end
  end

  defp image(rl, url) do
    response = get(rl, url, max_bytes: @max_bytes)

    with %Response{} <- response,
         true <- Response.ok?(response),
         type =
           (Response.header(response, "content-type") || "") |> String.split(";") |> hd() |> JS.trim() |> JS.lower(),
         true <- String.starts_with?(type, "image/"),
         true <- JS.number(Response.header(response, "content-length") || 0) <= @max_bytes,
         body = IO.iodata_to_binary(response.body),
         true <- byte_size(body) > 0 and byte_size(body) <= @max_bytes do
      %{body: body, type: type}
    else
      _ -> nil
    end
  end

  @doc "The site's icon, `%{body, type}`, or nil."
  @spec fetch_icon(Runlight.t(), String.t()) :: map() | nil
  def fetch_icon(rl, origin) do
    now = Runlight.now(rl)

    cached = State.get(rl.table, {:icon, origin})

    case cached do
      %{at: at, icon: icon} when (icon != nil and now - at < @day) or now - at < div(@day, 24) ->
        icon

      _ ->
        State.one_at_a_time(rl.table, {:icon, origin}, fn ->
          icon = look_up(rl, origin)
          State.put(rl.table, {:icon, origin}, %{at: now, icon: icon})
          icon
        end)
    end
  end

  defp look_up(rl, origin) do
    page = get(rl, "#{origin}/", max_bytes: 200_000, truncate: true)

    icon =
      if page && Response.ok?(page) && String.contains?(Response.header(page, "content-type") || "", "html") do
        # The head is all that is needed, so a huge page is not read past its start.
        body = IO.iodata_to_binary(page.body)
        html = JS.decode_utf8(binary_part(body, 0, min(byte_size(body), 200_000)))

        html
        |> icon_links(origin)
        |> Enum.take(4)
        |> Enum.find_value(&image(rl, &1))
      end

    icon || image(rl, "#{origin}/favicon.ico")
  end
end
