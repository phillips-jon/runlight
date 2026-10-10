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
    * `:public` - true to connect only to addresses on the public internet
      (`Runlight.Safefetch` sets it). A fetcher that cannot choose the
      address it connects to may ignore it, as Safefetch checks the name
      just before.

  `httpc/2` is the default, on Erlang's own `:httpc` with certificates
  verified against the system's.
  """

  alias Runlight.Http.Response
  alias Runlight.Safefetch

  @type fetcher :: (String.t(), keyword() -> {:ok, Response.t()} | {:error, term()})

  @doc "Fetches through `:httpc`."
  @spec httpc(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def httpc(url, opts \\ []) do
    case pin(url, Keyword.get(opts, :public, false)) do
      {:ok, target, host, socket_opts} -> httpc(url, target, host, socket_opts, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp httpc(url, target, host, socket_opts, opts) do
    ensure_started()
    method = opts |> Keyword.get(:method, "GET") |> String.downcase() |> String.to_existing_atom()
    given = Keyword.get(opts, :headers, [])
    given = if host && not List.keymember?(given, "host", 0), do: [{"host", host} | given], else: given
    headers = for {k, v} <- given, do: {String.to_charlist(k), String.to_charlist(v)}
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_bytes = Keyword.get(opts, :max_bytes)
    follow = Keyword.get(opts, :redirect, :follow) == :follow
    uri = String.to_charlist(target)

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

    request_opts = [sync: false, stream: :self, body_format: :binary] ++ socket_opts

    case :httpc.request(method, request, http_opts, request_opts) do
      {:ok, id} -> receive_answer(id, timeout, max_bytes, Keyword.get(opts, :truncate, false))
      {:error, reason} -> {:error, reason}
    end
  end

  # Where to connect. For a public fetch of a name, the name is resolved here and every address checked, and the
  # connection goes to one of them, so a name that answers differently a moment later gets nowhere. The URL keeps
  # its name for the Host header, SNI, and the certificate check. Socket options make httpc open a connection of
  # its own rather than reuse one another name left open to the same address.
  defp pin(url, false), do: {:ok, url, nil, []}

  defp pin(url, true) do
    uri = URI.parse(url)
    host = uri.host || ""
    literal = match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(host)))

    cond do
      literal and Safefetch.public_address?(host) ->
        {:ok, url, nil, []}

      literal ->
        {:error, :private}

      true ->
        case Safefetch.checked_address(host) do
          {:ok, address} ->
            family = if String.contains?(address, ":"), do: :inet6, else: :inet
            authority = if uri.port == URI.default_port(uri.scheme || ""), do: host, else: "#{host}:#{uri.port}"
            {:ok, URI.to_string(%{uri | host: address}), authority, [socket_opts: [ipfamily: family]]}

          error ->
            error
        end
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
