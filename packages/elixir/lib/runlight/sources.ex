defmodule Runlight.Sources do
  @moduledoc false
  # Internal. Where a visit came from: the page's campaign tags and click ids,
  # the referrer, and the channel they add up to (the SDK's sources.ts).

  alias Runlight.Data.Sources, as: Data
  alias Runlight.JS
  alias Runlight.SearchParams
  alias Runlight.Url

  @click_ids ["gclid", "gbraid", "wbraid", "dclid", "fbclid", "msclkid", "ttclid", "twclid", "li_fat_id", "yclid"]

  @by_host (for source <- Data.all(), host <- source.hosts, reduce: %{} do
              acc -> Map.put(acc, host, source)
            end)
  @by_alias (for source <- Data.all(), alias_name <- source.aliases, reduce: %{} do
               acc -> Map.put(acc, alias_name, source)
             end)

  defp clip(value, max \\ 200), do: value |> JS.nullish("") |> JS.trim() |> JS.slice(0, max)

  @doc "The host in lowercase without a leading www."
  @spec strip_www(String.t()) :: String.t()
  def strip_www(host), do: host |> JS.lower() |> String.replace(~r/^www\./, "")

  @doc """
  The most specific known source for a host: mail.google.com before
  google.com. Android apps send their package name as the referrer
  (com.google.android.gm for Gmail), which is matched the same way. Hosts
  known only by their shape (click trackers, webmail) come last.
  """
  @spec source_for_host(String.t()) :: map() | nil
  def source_for_host(host) do
    clean = strip_www(host)

    walk(clean) ||
      Enum.find_value(Data.patterns(), fn {pattern, name, kind} ->
        if Regex.match?(pattern, clean), do: %{name: name || clean, kind: kind, hosts: [], aliases: []}
      end)
  end

  defp walk(candidate) do
    if String.contains?(candidate, ".") do
      case Map.fetch(@by_host, candidate) do
        {:ok, found} ->
          found

        :error ->
          [_, rest] = :binary.split(candidate, ".")
          walk(rest)
      end
    end
  end

  @doc "The known source a utm_source, ref, or source parameter names, or nil."
  @spec source_for_alias(String.t()) :: map() | nil
  def source_for_alias(value) do
    key = value |> JS.lower() |> JS.trim()
    Map.get(@by_alias, key) || Map.get(@by_host, strip_www(key))
  end

  @doc """
  A path a person wrote, in the form paths are recorded: the path of a pasted
  URL, with a leading slash, percent-encoded as the browser's URL parser
  encodes it, and with a hash route kept, as parse_page keeps it. Nil when it
  is not a path or a URL.
  """
  @spec recorded_path(String.t()) :: String.t() | nil
  def recorded_path(input) do
    url =
      if Regex.match?(~r/^https?:\/\//i, input),
        do: Url.parse(input),
        else: Url.parse(if(String.starts_with?(input, "/"), do: input, else: "/" <> input), "https://x.invalid")

    if url, do: parse_page(url).path
  end

  @doc """
  A recorded path as people write it, for showing and exporting: /caf%C3%A9
  as /café. Only text is decoded; an encoded slash, space, or other mark that
  would change the path's meaning stays as it is.
  """
  @spec readable_path(String.t()) :: String.t()
  def readable_path(path) do
    Regex.replace(~r/(?:%[0-9A-Fa-f]{2})+/, path, fn run ->
      case JS.decode_uri_component(run) do
        nil -> run
        text -> if Regex.match?(~r/[\s\/?#%\p{C}]/u, text) or js_space?(text), do: run, else: text
      end
    end)
  end

  defp js_space?(text), do: text |> String.to_charlist() |> Enum.any?(&JS.space?/1)

  @doc "The page a URL is: its host, path, campaign tags, ref, and whether a click id came with it."
  @spec parse_page(Url.t()) :: map()
  def parse_page(%Url{} = url) do
    q = Url.search_params(url)
    path = if url.pathname == "", do: "/", else: url.pathname
    # The tracker only sends a hash when the site asked for hash routing.
    path = if JS.len16(url.hash) > 1, do: path <> url.hash, else: path

    %{
      hostname: strip_www(url.hostname),
      path: JS.slice(path, 0, 1000),
      utm: %{
        source: clip(SearchParams.get(q, "utm_source")),
        medium: JS.lower(clip(SearchParams.get(q, "utm_medium"))),
        campaign: clip(SearchParams.get(q, "utm_campaign")),
        term: clip(SearchParams.get(q, "utm_term")),
        content: clip(SearchParams.get(q, "utm_content"))
      },
      ref: clip(SearchParams.get(q, "ref") || SearchParams.get(q, "source")),
      paid: Enum.any?(@click_ids, &SearchParams.has?(q, &1))
    }
  end

  @doc """
  Where a visit came from. `internal_hosts` are the site's own hostnames: a
  referrer on one of them is navigation within the site, not a source.
  """
  @spec attribute(map(), String.t(), [String.t()]) :: map()
  def attribute(page, referrer, internal_hosts) do
    {referrer_host, referrer_path} =
      with true <- referrer != "",
           %Url{} = url <- Url.parse(referrer),
           true <- url.protocol in ["http:", "https:", "android-app:"],
           host = strip_www(url.hostname),
           true <- host != page.hostname and host not in internal_hosts do
        # Android apps refer as android-app://<package>/.
        {host, if(url.protocol == "android-app:", do: "", else: JS.slice(url.pathname, 0, 500))}
      else
        _ -> {"", ""}
      end

    tagged = if page.utm.source != "", do: page.utm.source, else: page.ref

    known =
      cond do
        tagged != "" -> source_for_alias(tagged)
        referrer_host != "" -> source_for_host(referrer_host)
        true -> nil
      end

    source = if known, do: known.name, else: if(tagged != "", do: tagged, else: referrer_host)

    kind =
      cond do
        known ->
          known.kind

        referrer_host != "" ->
          case source_for_host(referrer_host),
            do: (
              nil -> nil
              s -> s.kind
            )

        true ->
          nil
      end

    medium = page.utm.medium

    channel =
      cond do
        (page.paid or paid_medium?(medium)) and kind == "search" -> "Paid Search"
        kind == "ai" -> "AI"
        email_medium?(medium) or kind == "email" -> "Email"
        kind == "search" -> "Organic Search"
        social_medium?(medium) or kind == "social" -> "Social"
        page.utm.source != "" or page.utm.medium != "" or page.utm.campaign != "" -> "Campaign"
        referrer_host != "" or page.ref != "" -> "Referral"
        true -> "Direct"
      end

    %{referrer_host: referrer_host, referrer_path: referrer_path, source: source, channel: channel}
  end

  defp paid_medium?(m),
    do: m in ~w(cpc ppc paid paidsearch paid_search paid-search sem cpm cpv display banner retargeting)

  defp email_medium?(m), do: m in ~w(email e-mail newsletter mail)

  defp social_medium?(m),
    do: m in ~w(social social-network social-media sm social_network social_media paid_social paid-social paidsocial)
end
