defmodule Runlight.Fetch do
  @moduledoc """
  Outgoing requests, the stand-in for JavaScript's fetch(). Everything that
  calls another server (mail services, importers, connected installs, the
  assistant's providers, site icons) goes through the instance's fetcher, so
  tests can pass a fake.

  A fetcher is a function of two arguments, the URL and options, that answers
  `{:ok, %Runlight.Http.Response{}}` or `{:error, reason}` when no answer came
  back (refused, timed out, bad TLS). The options:

    * `:method` - default "GET".
    * `:headers` - a list of `{name, value}` pairs, names lowercase.
    * `:body` - text.
    * `:redirect` - `:follow` (default) or `:manual`, which hands back a 3xx.
    * `:timeout` - the whole request's limit in milliseconds, default 30000.
    * `:max_bytes` - stop reading past this and answer `{:error, :too_long}`,
      or with `truncate: true` hand back the first `max_bytes`.

  `httpc/2` is the default, on Erlang's own `:httpc` with certificates
  verified against the system's.
  """

  alias Runlight.Http.Response

  @type fetcher :: (String.t(), keyword() -> {:ok, Response.t()} | {:error, term()})

  @doc "Fetches through `:httpc`."
  @spec httpc(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def httpc(url, opts \\ []) do
    ensure_started()
    method = opts |> Keyword.get(:method, "GET") |> String.downcase() |> String.to_existing_atom()
    headers = for {k, v} <- Keyword.get(opts, :headers, []), do: {String.to_charlist(k), String.to_charlist(v)}
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_bytes = Keyword.get(opts, :max_bytes)
    follow = Keyword.get(opts, :redirect, :follow) == :follow
    uri = String.to_charlist(url)

    request =
      if method in [:get, :head, :delete, :options] and Keyword.get(opts, :body) in [nil, ""] do
        {uri, headers}
      else
        type =
          Enum.find_value(Keyword.get(opts, :headers, []), ~c"text/plain;charset=UTF-8", fn {k, v} ->
            if k == "content-type", do: String.to_charlist(v)
          end)

        {uri, Enum.reject(headers, fn {k, _} -> k == ~c"content-type" end), type, Keyword.get(opts, :body, "")}
      end

    http_opts = [timeout: timeout, connect_timeout: min(timeout, 10_000), autoredirect: follow, ssl: ssl_options(url)]

    case :httpc.request(method, request, http_opts, sync: false, stream: :self, body_format: :binary) do
      {:ok, id} -> receive_answer(id, timeout, max_bytes, Keyword.get(opts, :truncate, false))
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_answer(id, timeout, max_bytes, truncate) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(id, deadline, max_bytes, truncate, nil, [], 0)
  end

  defp collect(id, deadline, max_bytes, truncate, head, acc, size) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:http, {^id, {{_, status, _}, headers, body}}} ->
        case cap(body, max_bytes, truncate) do
          :too_long -> {:error, :too_long}
          body -> {:ok, answer(status, headers, body)}
        end

      {:http, {^id, :stream_start, headers}} ->
        collect(id, deadline, max_bytes, truncate, {200, headers}, acc, size)

      {:http, {^id, :stream, chunk}} ->
        size = size + byte_size(chunk)

        if max_bytes && size > max_bytes do
          :httpc.cancel_request(id)

          if truncate do
            body = IO.iodata_to_binary(Enum.reverse([chunk | acc]))
            {status, headers} = head || {200, []}
            {:ok, answer(status, headers, binary_part(body, 0, max_bytes))}
          else
            {:error, :too_long}
          end
        else
          collect(id, deadline, max_bytes, truncate, head, [chunk | acc], size)
        end

      {:http, {^id, :stream_end, headers}} ->
        {status, _} = head || {200, []}
        {:ok, answer(status, headers, IO.iodata_to_binary(Enum.reverse(acc)))}

      {:http, {^id, {:error, reason}}} ->
        {:error, reason}
    after
      left ->
        :httpc.cancel_request(id)
        {:error, :timeout}
    end
  end

  defp cap(body, nil, _truncate), do: body
  defp cap(body, max, _truncate) when byte_size(body) <= max, do: body
  defp cap(body, max, true), do: binary_part(body, 0, max)
  defp cap(_body, _max, false), do: :too_long

  defp answer(status, headers, body) do
    %Response{
      status: status,
      headers: for({k, v} <- headers, do: {k |> to_string() |> String.downcase(), to_string(v)}),
      body: body
    }
  end

  defp ssl_options(url) do
    if String.starts_with?(url, "https:") do
      host =
        url |> URI.parse() |> Map.get(:host, "") |> to_string() |> String.trim_leading("[") |> String.trim_trailing("]")

      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        depth: 4
      ]
    else
      []
    end
  end

  defp ensure_started do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end
end
