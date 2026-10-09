defmodule Runlight.Test.Conformance do
  @moduledoc false
  # Plays a scenario from conformance/http.json exactly as play() in
  # packages/sdk/test/http-conformance.ts does, and returns each step's answer,
  # normalized, in the shape of the file's `expect`. Keep it in step with the
  # TypeScript runner (and the PHP one in packages/php/tests/Conformance).

  alias Runlight.Crypto
  alias Runlight.Http.Request
  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.SearchParams
  alias Runlight.Url

  @env ~w(RUNLIGHT_TOKEN RUNLIGHT_SECRET CRON_SECRET RUNLIGHT_OBSERVE_KEY NODE_ENV RUNLIGHT_ENV)
  @headers ~w(content-type cache-control location set-cookie www-authenticate allow content-disposition content-security-policy x-frame-options referrer-policy x-content-type-options x-robots-tag access-control-allow-origin access-control-allow-methods access-control-allow-headers access-control-max-age)
  @random ~w(token secret hint version library language ticket recovery)

  def scenarios, do: Runlight.Test.Fixtures.conformance("http.json")["scenarios"]

  @doc "Every step's answer, normalized, for a scenario played on a store."
  def play(scenario, store) do
    saved = for name <- @env, do: {name, System.get_env(name)}
    for name <- @env, do: System.delete_env(name)
    {:ok, clock} = Agent.start_link(fn -> scenario["start"] end)
    {:ok, fetched} = Agent.start_link(fn -> [] end)
    upstream = scenario["upstream"] || []

    try do
      options = scenario["options"] || Object.new()

      sites =
        cond do
          options["managedSites"] -> [managed_sites: true]
          scenario["sites"] -> [sites: Enum.map(scenario["sites"], &plain/1)]
          true -> [site: plain(scenario["site"])]
        end

      rl =
        Runlight.new(
          [store: store, now: fn -> Agent.get(clock, & &1) end, fetcher: fetcher(upstream, fetched)] ++
            sites ++
            if(JS.truthy?(options["secret"]), do: [secret: options["secret"]], else: []) ++
            if(Object.has_key?(options, "rateLimit"), do: [rate_limit: options["rateLimit"]], else: [])
        )

      routes =
        Runlight.routes(
          rl,
          [
            token: if(scenario["token"] == nil, do: false, else: scenario["token"]),
            observe_key: options["observeKey"] || "",
            cron_secret: options["cronSecret"] || ""
          ] ++
            if(options["accounts"], do: [accounts: true], else: []) ++
            if(JS.truthy?(options["origin"]), do: [origin: options["origin"]], else: [])
        )

      {answers, _, _} =
        Enum.reduce(scenario["steps"], {[], %{}, %{}}, fn step, {answers, kept, jars} ->
          try do
            {answer, kept, jars} = step(step, rl, routes, clock, fetched, kept, jars)
            {[answer | answers], kept, jars}
          rescue
            error ->
              reraise RuntimeError,
                      [message: "#{scenario["name"]}: #{step["method"]} #{step["path"]}: " <> Exception.format(:error, error, __STACKTRACE__)],
                      __STACKTRACE__
          end
        end)

      Enum.reverse(answers)
    after
      Agent.stop(clock)
      Agent.stop(fetched)

      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end
  end

  defp plain(%Object{} = o), do: Map.new(Object.to_list(o), fn {k, v} -> {String.to_atom(k), v} end)

  defp fetcher(upstream, fetched) do
    fn url, opts ->
      method = opts |> Keyword.get(:method, "GET") |> String.upcase()
      given = opts |> Keyword.get(:headers, []) |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
      given = given |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)) |> Enum.map(fn {k, vs} -> {k, Enum.join(vs, ", ")} end) |> Enum.sort()
      text = Keyword.get(opts, :body) || ""
      seen = JS.obj(method: method, url: url)
      seen = if given != [], do: Object.put(seen, "headers", Object.new(given)), else: seen
      type = Enum.find_value(given, "", fn {k, v} -> if k == "content-type", do: v end)
      seen = if text != "", do: Object.put(seen, "body", sent_body(text, type)), else: seen
      Agent.update(fetched, &(&1 ++ [%{seen: seen, text: text}]))

      match =
        Enum.find(upstream, fn u ->
          String.starts_with?(url, u["url"]) and (u["method"] in [nil, ""] or u["method"] == method)
        end)

      if match == nil do
        {:error, :fetch_failed}
      else
        has_body = Object.has_key?(match, "body")
        body = match["body"]
        text_body = if not has_body, do: "", else: if(is_binary(body), do: body, else: JS.stringify(body))
        json_type = has_body and (body == nil or is_list(body) or JS.object?(body))
        headers = if json_type, do: [{"content-type", "application/json"}], else: []

        headers =
          Enum.reduce(Object.to_list(match["headers"] || Object.new()), headers, fn {k, v}, acc ->
            List.keystore(acc, String.downcase(k), 0, {String.downcase(k), JS.string(v)})
          end)

        max = Keyword.get(opts, :max_bytes)

        cond do
          max != nil and byte_size(text_body) > max and not Keyword.get(opts, :truncate, false) -> {:error, :too_long}
          max != nil and byte_size(text_body) > max -> {:ok, %Response{status: match["status"] || 200, headers: headers, body: binary_part(text_body, 0, max)}}
          true -> {:ok, %Response{status: match["status"] || 200, headers: headers, body: text_body}}
        end
      end
    end
  end

  defp sent_body(text, type) do
    if String.starts_with?(type, "application/x-www-form-urlencoded") do
      text |> SearchParams.parse() |> Enum.reduce(Object.new(), fn {k, v}, o -> Object.put(o, k, v) end)
    else
      case JS.parse(text) do
        {:ok, v} -> v
        {:error, _} -> text
      end
    end
  end

  defp step(step, rl, routes, clock, fetched, kept, jars) do
    Agent.update(clock, &(&1 + (step["advance"] || 0)))
    now = Agent.get(clock, & &1)

    headers =
      Enum.map(Object.to_list(step["headers"] || Object.new()), fn {k, v} -> {String.downcase(k), fill_totp(v, kept, now)} end)

    {body, headers} =
      cond do
        step["form"] ->
          fields = step["form"] |> fill_deep(kept, now) |> Object.to_list() |> Enum.map(fn {k, v} -> {k, JS.string(v)} end)
          {SearchParams.to_string(fields), put_new(headers, "content-type", "application/x-www-form-urlencoded")}

        Object.has_key?(step, "body") ->
          b = step["body"]
          {if(is_binary(b), do: fill_totp(b, kept, now), else: JS.stringify(fill_deep(b, kept, now))), headers}

        true ->
          {nil, headers}
      end

    # JavaScript's Request gives a string body this type when none is named.
    headers = if body != nil, do: put_new(headers, "content-type", "text/plain;charset=UTF-8"), else: headers
    jar_name = if step["jar"] == false, do: nil, else: step["jar"] || "main"
    jar = if jar_name, do: Map.get(jars, jar_name, []), else: nil

    headers =
      if jar not in [nil, []] and not List.keymember?(headers, "cookie", 0),
        do: headers ++ [{"cookie", Enum.map_join(jar, "; ", fn {k, v} -> "#{k}=#{v}" end)}],
        else: headers

    to = step["to"] || "routes"
    prefix = if to == "routes" and not JS.truthy?(step["absolute"]), do: "/runlight", else: ""
    raw = "https://#{step["host"] || "example.com"}#{prefix}#{fill_totp(step["path"], kept, now)}"
    url = case Url.parse(raw), do: (nil -> raw; u -> Url.href(u))
    request = Request.new(url, method: step["method"], headers: headers, body: body || "")
    Agent.update(fetched, fn _ -> [] end)

    answer =
      case to do
        "links" -> Runlight.link_handler(rl, request)
        "linkDomain" -> Runlight.link_domain_response(rl, request)
        _ -> Runlight.Routes.handle(routes, request)
      end

    Runlight.idle(rl)
    sent_out = Agent.get(fetched, & &1)
    outbound = Enum.map(sent_out, &normalize(&1.seen))

    if answer == nil do
      out = JS.obj(pass: true)
      out = if outbound != [], do: Object.put(out, "fetched", outbound), else: out
      {out, kept, jars}
    else
      bytes = IO.iodata_to_binary(answer.body)
      text = JS.decode_utf8(bytes)
      type = (Response.header(answer, "content-type") || "") |> String.split(";") |> hd() |> String.trim()

      parsed =
        if type != "application/zip" and text != "" do
          case JS.parse(text) do
            {:ok, v} -> {:ok, v}
            _ -> :none
          end
        else
          :none
        end

      kept =
        Enum.reduce(Object.to_list(step["capture"] || Object.new()), kept, fn {name, spec}, kept ->
          Map.put(kept, name, capture(spec, answer, text, parsed, sent_out))
        end)

      jars =
        if jar_name do
          jar =
            Enum.reduce(Response.set_cookies(answer), jar, fn cookie, jar ->
              [pair | attributes] = String.split(cookie, ";")

              {name, value} =
                case :binary.match(pair, "=") do
                  {at, _} -> {String.trim(binary_part(pair, 0, at)), String.trim(binary_part(pair, at + 1, byte_size(pair) - at - 1))}
                  :nomatch -> {String.trim(String.slice(pair, 0..-2//1)), String.trim(pair)}
                end

              clears = Enum.any?(attributes, &Regex.match?(~r/^\s*max-age=0\s*$/i, &1))
              if value == "" or clears, do: List.keydelete(jar, name, 0), else: List.keystore(jar, name, 0, {name, value})
            end)

          Map.put(jars, jar_name, jar)
        else
          jars
        end

      sent =
        Enum.reduce(@headers, Object.new(), fn name, sent ->
          cond do
            name == "set-cookie" ->
              cookies = Response.set_cookies(answer)
              if cookies != [], do: Object.put(sent, name, Enum.map(cookies, &cookie_shape/1)), else: sent

            (value = Response.header(answer, name)) not in [nil, ""] ->
              Object.put(sent, name, if(name == "content-type", do: value |> String.split(";") |> hd() |> String.trim(), else: normalize(value)))

            true ->
              sent
          end
        end)

      out = JS.obj(status: answer.status)
      out = if Object.size(sent) > 0, do: Object.put(out, "headers", sent), else: out
      out = case parsed, do: ({:ok, v} -> Object.put(out, "body", normalize(v)); :none -> out)
      out = if parsed == :none and type in ["text/plain", "text/csv"], do: Object.put(out, "text", normalize(text)), else: out

      out =
        if type == "application/zip",
          do: Object.put(out, "files", Enum.map(unzip(bytes), &JS.obj(name: &1.name, text: normalize(&1.text)))),
          else: out

      out = if step["look"], do: Object.put(out, "found", Enum.map(step["look"], &String.contains?(text, &1))), else: out
      out = if outbound != [], do: Object.put(out, "fetched", outbound), else: out
      {out, kept, jars}
    end
  end

  defp put_new(headers, name, value), do: if(List.keymember?(headers, name, 0), do: headers, else: headers ++ [{name, value}])

  defp capture(spec, answer, text, parsed, sent_out) do
    {source, pattern} =
      case :binary.match(spec, "~") do
        {at, _} -> {binary_part(spec, 0, at), binary_part(spec, at + 1, byte_size(spec) - at - 1)}
        :nomatch -> {spec, nil}
      end

    value =
      cond do
        source == "text" ->
          text

        source == "fetched" ->
          Enum.map_join(sent_out, "\n", & &1.text)

        String.starts_with?(source, "header:") ->
          header = source |> String.replace_prefix("header:", "") |> String.downcase()
          if header == "set-cookie", do: Enum.join(Response.set_cookies(answer), "\n"), else: Response.header(answer, header) || ""

        true ->
          value = case parsed, do: ({:ok, v} -> dig(v, source); :none -> nil)
          if value in [nil, :undefined], do: "", else: JS.string(value)
      end

    if pattern == nil do
      value
    else
      case Regex.run(Regex.compile!(pattern, "u"), value) do
        [_, group | _] -> group
        _ -> ""
      end
    end
  end

  defp dig(value, path) do
    Enum.reduce(String.split(path, "."), value, fn k, v -> if JS.objectish?(v), do: JS.prop(v, k), else: nil end)
  end

  defp fill_totp(text, kept, now) do
    out =
      Regex.replace(~r/\{\{totp:(\w+)\}\}/, text, fn _, name ->
        Crypto.totp(Map.get(kept, name, ""), Integer.floor_div(now, 30_000))
      end)

    Regex.replace(~r/\{\{(\w+)\}\}/, out, fn _, name -> Map.get(kept, name, "") end)
  end

  defp fill_deep(v, kept, now) when is_binary(v), do: fill_totp(v, kept, now)
  defp fill_deep(v, kept, now) when is_list(v), do: Enum.map(v, &fill_deep(&1, kept, now))

  defp fill_deep(%Object{} = o, kept, now),
    do: o |> Object.to_list() |> Enum.map(fn {k, v} -> {k, fill_deep(v, kept, now)} end) |> Object.new()

  defp fill_deep(v, _kept, _now), do: v

  @js_space "\\t\\n\\x{0B}\\f\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"

  def scrub(text) do
    text
    |> then(&Regex.replace(Regex.compile!("([?&](?:code|ticket|secret|code_challenge)=)[^&#" <> @js_space <> "\"'<>]+", "u"), &1, "\\1<value>"))
    |> then(&Regex.replace(~r/(?<![A-Za-z0-9])[a-f0-9]{24,}(?![A-Za-z0-9])/u, &1, "<hex>"))
    |> then(&Regex.replace(~r/(?<![A-Za-z0-9_])rlo?_[A-Za-z0-9]{20,}(?![A-Za-z0-9])/u, &1, "<key>"))
  end

  def normalize(value, key \\ "")
  def normalize(list, key) when is_list(list), do: Enum.map(list, &normalize(&1, key))

  def normalize(%Object{} = o, _key),
    do: o |> Object.to_list() |> Enum.map(fn {k, v} -> {k, normalize(v, k)} end) |> Object.new()

  def normalize(s, key) when is_binary(s) do
    if key in @random or Regex.match?(~r/\Arlo?_[A-Za-z0-9]+\z/, s) or Regex.match?(~r/\A[a-f0-9]{24}\z/, s),
      do: "<#{if key == "", do: "value", else: key}>",
      else: scrub(s)
  end

  def normalize(v, _key), do: v

  defp cookie_shape(header) do
    Regex.replace(~r/^([^=;]+)=([^;]*)/, header, fn _, name, value -> "#{name}=#{if value != "", do: "<value>", else: ""}" end, global: false)
  end

  defp unzip(bytes), do: unzip(bytes, [])

  defp unzip(<<0x04034B50::little-32, _::16, _::16, method::little-16, _::32, _::32, size::little-32, _::32, name_len::little-16, extra::little-16, rest::binary>>, acc) do
    <<name::binary-size(name_len), _::binary-size(extra), data::binary-size(size), rest::binary>> = rest
    text = if method == 8, do: :zlib.unzip(data), else: data
    unzip(rest, acc ++ [%{name: JS.decode_utf8(name), text: JS.decode_utf8(text)}])
  end

  defp unzip(_, acc), do: acc

  @doc "Answers as one text to compare: object keys sorted, as deepEqual ignores their order."
  def canonical(v), do: JS.stringify(sorted(v))

  defp sorted(%Object{} = o), do: o |> Object.to_list() |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> {k, sorted(v)} end) |> Object.new()
  defp sorted(l) when is_list(l), do: Enum.map(l, &sorted/1)
  defp sorted(v), do: v
end
