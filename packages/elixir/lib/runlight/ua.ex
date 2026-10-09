defmodule Runlight.Ua do
  @moduledoc false
  # Internal. What a user agent says: an AI agent, a bot, or a browser, its
  # version, the system, and the device (the SDK's ua.ts).

  alias Runlight.Data.Agents
  alias Runlight.JS

  @doc "The AI agent a user agent names, or nil."
  @spec ai_agent(String.t()) :: map() | nil
  def ai_agent(ua) do
    lower = JS.lower(ua)
    Enum.find(Agents.all(), &String.contains?(lower, &1.token))
  end

  @doc "Whether the user agent is clearly not a person in a browser."
  @spec bot?(String.t()) :: boolean()
  def bot?(ua) do
    if JS.len16(ua) < 20 or not Regex.match?(~r/mozilla|opera/i, ua),
      do: true,
      else: Regex.match?(Agents.bot_pattern(), ua)
  end

  defp browsers do
    [
      {"Edge", ~r/(?:Edg|EdgA|EdgiOS|Edge)\/(\d+)/},
      {"Opera", ~r/(?:OPR|OPiOS|Opera)\/(\d+)/},
      {"Samsung Internet", ~r/SamsungBrowser\/(\d+)/},
      {"Yandex Browser", ~r/YaBrowser\/(\d+)/},
      {"Vivaldi", ~r/Vivaldi\/(\d+)/},
      {"UC Browser", ~r/UCBrowser\/(\d+)/},
      {"DuckDuckGo", ~r/(?:Ddg|DuckDuckGo)\/(\d+)/},
      {"Facebook", ~r/FB(?:AV|_IAB)\/(\d+)/},
      {"Instagram", ~r/Instagram (\d+)/},
      {"Firefox", ~r/(?:Firefox|FxiOS)\/(\d+)/},
      {"Chrome", ~r/(?:CriOS|Chrome)\/(\d+)/},
      {"Safari", ~r/Version\/(\d+)[\d.]* (?:Mobile\/\S+ )?Safari\//},
      {"Internet Explorer", ~r/(?:MSIE |Trident\/.*rv:)(\d+)/}
    ]
  end

  @windows %{"10.0" => "10", "6.3" => "8.1", "6.2" => "8", "6.1" => "7", "6.0" => "Vista", "5.1" => "XP"}

  defp unquote_hint(nil), do: ""
  defp unquote_hint(value), do: value |> String.replace("\"", "") |> JS.trim()

  @doc """
  The browser, its major version, the system, its version, and the device.
  `hints` are the low entropy client hints (`brands`, `mobile`, `platform`),
  and `screen_width` the screen's width when the tracker sent one.
  """
  @spec parse_client(String.t(), map(), integer() | nil) :: map()
  def parse_client(ua, hints \\ %{}, screen_width \\ nil) do
    {browser, version} =
      Enum.find_value(browsers(), {"Other", ""}, fn {name, pattern} ->
        case Regex.run(pattern, ua) do
          [_, v | _] -> {name, v}
          [_] -> {name, ""}
          nil -> nil
        end
      end)

    browser = if browser == "Chrome" and Regex.match?(~r/; wv\)/, ua), do: "Android WebView", else: browser
    # Brave looks like Chrome in the user agent but names itself in the hints.
    browser = if browser == "Chrome" and Regex.match?(~r/"Brave"/, hints[:brands] || ""), do: "Brave", else: browser

    {os, os_version} =
      cond do
        m = Regex.run(~r/Windows NT (\d+\.\d+)/, ua) -> {"Windows", Map.get(@windows, Enum.at(m, 1), "")}
        m = Regex.run(~r/(?:iPhone|iPad|iPod).*? OS (\d+)/, ua) -> {"iOS", Enum.at(m, 1)}
        m = Regex.run(~r/Android (\d+)/, ua) -> {"Android", Enum.at(m, 1)}
        Regex.match?(~r/Android/, ua) -> {"Android", ""}
        Regex.match?(~r/CrOS/, ua) -> {"Chrome OS", ""}
        # macOS froze its version in the user agent at 10.15, so it says nothing.
        Regex.match?(~r/Mac OS X|Macintosh/, ua) -> {"macOS", ""}
        Regex.match?(~r/Linux|X11/, ua) -> {"Linux", ""}
        true -> {"Other", ""}
      end

    platform = unquote_hint(hints[:platform])
    os = if os == "Other" and platform != "", do: if(platform == "macOS", do: "macOS", else: platform), else: os

    {device, os} =
      cond do
        Regex.match?(~r/iPad|Tablet|PlayBook|Silk/, ua) or (os == "Android" and not Regex.match?(~r/Mobile/, ua)) ->
          {"tablet", os}

        Regex.match?(~r/Mobi|iPhone|iPod|Opera Mini|IEMobile/, ua) or unquote_hint(hints[:mobile]) == "?1" ->
          {"mobile", os}

        os == "macOS" and screen_width != nil and screen_width in [768, 810, 820, 834, 1024] ->
          # iPadOS asks for desktop sites with a Mac user agent; the screen gives it away.
          {"tablet", "iOS"}

        true ->
          {"desktop", os}
      end

    %{browser: browser, browser_version: version, os: os, os_version: os_version, device: device}
  end
end
