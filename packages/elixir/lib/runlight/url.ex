defmodule Runlight.Url do
  @moduledoc """
  A URL parsed as the WHATWG URL standard parses one, as `new URL()` does in
  JavaScript, so every port reads a request's address the same way.

  Documented for its type; its functions are internal and can change in
  any release.
  """

  # Internal: not the package's API, and it can change in any release.
  #
  # An absolute URL, parsed the way browsers and JavaScript's URL do for http
  # and https: the host lowercased, backslashes read as slashes, dot segments
  # resolved, and the path and query percent-encoded with the WHATWG sets, so a
  # path recorded here matches what the tracker sent and what the TypeScript
  # SDK stores (conformance/url.json holds every port to it). Other schemes
  # (mailto:, android-app://) are kept as they came.

  alias Runlight.SearchParams

  defstruct protocol: "",
            username: "",
            password: "",
            hostname: "",
            port: "",
            pathname: "",
            search: "",
            hash: "",
            authority: false

  @type t :: %__MODULE__{}

  @default_ports %{"http:" => "80", "https:" => "443", "ws:" => "80", "wss:" => "443", "ftp:" => "21"}

  @path_set ~c" \"#<>?`{}"
  @query_set ~c" \"#<>'"
  @fragment_set ~c" \"<>`"
  @userinfo_set ~c" \"#<>?`{}/:;=@[\\]^|"

  @doc "`new URL(input, base)`, or nil where it throws."
  @spec parse(String.t() | nil, String.t() | t() | nil) :: t() | nil
  def parse(input, base \\ nil)
  def parse(nil, _base), do: nil

  def parse(input, base) do
    new(input, base)
  rescue
    ArgumentError -> nil
  end

  @doc "`new URL(input, base)`, raising ArgumentError as the constructor throws."
  @spec new(String.t(), String.t() | t() | nil) :: t()
  def new(input, base \\ nil) do
    input = input |> trim_controls() |> String.replace(["\t", "\n", "\r"], "")

    case Regex.run(~r/\A([a-zA-Z][a-zA-Z0-9+.\-]*):(.*)\z/s, input) do
      [_, scheme, rest] ->
        protocol = String.downcase(scheme) <> ":"
        absolute(%__MODULE__{protocol: protocol}, rest)

      nil ->
        case base do
          nil -> raise ArgumentError, "Invalid URL: #{input}"
          %__MODULE__{} = b -> resolve(input, b)
          b when is_binary(b) -> resolve(input, new(b))
        end
    end
  end

  defp trim_controls(text) do
    text
    |> String.replace(~r/\A[\x00-\x20]+/, "")
    |> String.replace(~r/[\x00-\x20]+\z/, "")
  end

  defp special?(%__MODULE__{protocol: p}), do: Map.has_key?(@default_ports, p)

  defp absolute(url, rest) do
    if special?(url) do
      rest = rest |> String.replace("\\", "/") |> String.trim_leading("/")
      {authority, tail} = split_authority(rest)
      url |> authority(authority) |> tail(tail, "/")
    else
      if String.starts_with?(rest, "//") do
        rest = binary_part(rest, 2, byte_size(rest) - 2)
        {authority, tail} = split_authority(rest)
        url = opaque_authority(url, authority)
        tail(%{url | authority: true}, tail, "")
      else
        {rest, hash} = cut(rest, "#")
        {path, search} = cut(rest, "?")
        %{url | pathname: path, search: search, hash: hash}
      end
    end
  end

  defp split_authority(rest) do
    case :binary.match(rest, ["/", "?", "#"]) do
      {at, _} -> {binary_part(rest, 0, at), binary_part(rest, at, byte_size(rest) - at)}
      :nomatch -> {rest, ""}
    end
  end

  @doc "`url.host`: the hostname, with the port when there is one."
  @spec host(t()) :: String.t()
  def host(%__MODULE__{hostname: h, port: ""}), do: h
  def host(%__MODULE__{hostname: h, port: p}), do: "#{h}:#{p}"

  @doc "`url.origin`."
  @spec origin(t()) :: String.t()
  def origin(url), do: if(special?(url), do: "#{url.protocol}//#{host(url)}", else: "null")

  @doc "`url.href`, which `toString()` gives too."
  @spec href(t()) :: String.t()
  def href(%__MODULE__{} = url) do
    if not special?(url) and not url.authority do
      url.protocol <> url.pathname <> url.search <> url.hash
    else
      auth =
        if url.username != "" or url.password != "",
          do: url.username <> if(url.password != "", do: ":" <> url.password, else: "") <> "@",
          else: ""

      "#{url.protocol}//#{auth}#{host(url)}#{url.pathname}#{url.search}#{url.hash}"
    end
  end

  @doc "`url.searchParams`."
  @spec search_params(t()) :: SearchParams.t()
  def search_params(%__MODULE__{search: s}), do: SearchParams.parse(s)

  @doc "The URL with these parameters as its query, as changing url.searchParams does."
  @spec with_params(t(), SearchParams.t()) :: t()
  def with_params(url, params) do
    text = SearchParams.to_string(params)
    %{url | search: if(text == "", do: "", else: "?" <> text)}
  end

  @doc "Assigning url.search: one leading ? is dropped and the rest percent-encoded; empty removes it."
  @spec put_search(t(), String.t()) :: t()
  def put_search(url, ""), do: %{url | search: ""}

  def put_search(url, search) do
    search = String.replace(search, ["\t", "\n", "\r"], "")
    search = if String.starts_with?(search, "?"), do: binary_part(search, 1, byte_size(search) - 1), else: search
    %{url | search: "?" <> encode(search, @query_set)}
  end

  @doc "Assigning url.pathname."
  @spec put_pathname(t(), String.t()) :: t()
  def put_pathname(url, path) do
    path = String.replace(path, ["\t", "\n", "\r"], "")
    path = if special?(url), do: String.replace(path, "\\", "/"), else: path
    %{url | pathname: path(if String.starts_with?(path, "/"), do: path, else: "/" <> path)}
  end

  defp resolve(input, %__MODULE__{} = base) do
    url = %__MODULE__{protocol: base.protocol}
    input = if special?(url), do: String.replace(input, "\\", "/"), else: input

    cond do
      String.starts_with?(input, "//") ->
        rest = if special?(url), do: String.trim_leading(input, "/"), else: binary_part(input, 2, byte_size(input) - 2)
        {authority, tail} = split_authority(rest)
        url |> authority(authority) |> tail(tail, "/")

      true ->
        url = %{url | username: base.username, password: base.password, hostname: base.hostname, port: base.port}

        case input do
          "" ->
            %{url | pathname: base.pathname, search: base.search, hash: ""}

          "#" <> frag ->
            %{
              url
              | pathname: base.pathname,
                search: base.search,
                hash: if(frag == "", do: "", else: "#" <> encode(frag, @fragment_set))
            }

          "?" <> rest ->
            {query, hash} = cut(rest, "#")

            %{
              url
              | pathname: base.pathname,
                search: if(query == "", do: "", else: "?" <> encode(query, @query_set)),
                hash:
                  if(hash == "", do: "", else: "#" <> encode(binary_part(hash, 1, byte_size(hash) - 1), @fragment_set))
            }

          "/" <> _ ->
            tail(url, input, "/")

          _ ->
            dir =
              case :binary.matches(base.pathname, "/") do
                [] -> ""
                matches -> binary_part(base.pathname, 0, elem(List.last(matches), 0) + 1)
              end

            tail(url, dir <> input, "/")
        end
    end
  end

  defp authority(url, authority) do
    {url, authority} =
      case :binary.matches(authority, "@") do
        [] ->
          {url, authority}

        matches ->
          {at, _} = List.last(matches)
          user = binary_part(authority, 0, at)
          rest = binary_part(authority, at + 1, byte_size(authority) - at - 1)
          {name, pass} = cut(user, ":")
          pass = if pass == "", do: "", else: encode(binary_part(pass, 1, byte_size(pass) - 1), @userinfo_set)
          {%{url | username: encode(name, @userinfo_set), password: pass}, rest}
      end

    {host, port} =
      if String.starts_with?(authority, "[") do
        case :binary.match(authority, "]") do
          :nomatch ->
            raise ArgumentError, "Invalid URL"

          {close, _} ->
            host = String.downcase(binary_part(authority, 0, close + 1))
            after_host = binary_part(authority, close + 1, byte_size(authority) - close - 1)

            port =
              case after_host do
                "" -> ""
                ":" <> p -> p
                _ -> raise ArgumentError, "Invalid URL"
              end

            {host, port}
        end
      else
        {host, port} =
          case :binary.matches(authority, ":") do
            [] ->
              {authority, ""}

            matches ->
              {at, _} = List.last(matches)
              {binary_part(authority, 0, at), binary_part(authority, at + 1, byte_size(authority) - at - 1)}
          end

        {domain(host), port}
      end

    if host == "", do: raise(ArgumentError, "Invalid URL")

    port =
      cond do
        port == "" ->
          ""

        not Regex.match?(~r/\A[0-9]+\z/, port) ->
          raise ArgumentError, "Invalid URL"

        String.to_integer(port) > 65_535 ->
          raise ArgumentError, "Invalid URL"

        true ->
          p = Integer.to_string(String.to_integer(port))
          if p == @default_ports[url.protocol], do: "", else: p
      end

    %{url | hostname: host, port: port}
  end

  defp opaque_authority(url, authority) do
    {url, authority} =
      case :binary.matches(authority, "@") do
        [] ->
          {url, authority}

        matches ->
          {at, _} = List.last(matches)
          {name, pass} = cut(binary_part(authority, 0, at), ":")
          pass = if pass == "", do: "", else: encode(binary_part(pass, 1, byte_size(pass) - 1), @userinfo_set)

          {%{url | username: encode(name, @userinfo_set), password: pass},
           binary_part(authority, at + 1, byte_size(authority) - at - 1)}
      end

    {host, port} =
      case :binary.matches(authority, ":") do
        [] ->
          {authority, ""}

        matches ->
          {at, _} = List.last(matches)
          {binary_part(authority, 0, at), binary_part(authority, at + 1, byte_size(authority) - at - 1)}
      end

    if Regex.match?(~r/[\x00 #\/:<>?@\[\\\]^|]/, host) or
         (port != "" and (not Regex.match?(~r/\A[0-9]+\z/, port) or String.to_integer(port) > 65_535)),
       do: raise(ArgumentError, "Invalid URL")

    %{url | hostname: encode(host, []), port: if(port == "", do: "", else: Integer.to_string(String.to_integer(port)))}
  end

  defp tail(url, rest, empty) do
    {rest, hash} = cut(rest, "#")
    {path, query} = cut(rest, "?")

    pathname =
      if path == "" and empty == "", do: "", else: path(if path == "", do: empty, else: path)

    search =
      if byte_size(query) > 1, do: "?" <> encode(binary_part(query, 1, byte_size(query) - 1), @query_set), else: ""

    hash = if byte_size(hash) > 1, do: "#" <> encode(binary_part(hash, 1, byte_size(hash) - 1), @fragment_set), else: ""
    %{url | pathname: pathname, search: search, hash: hash}
  end

  # The part before `mark`, and the rest starting with it.
  defp cut(text, mark) do
    case :binary.match(text, mark) do
      {at, _} -> {binary_part(text, 0, at), binary_part(text, at, byte_size(text) - at)}
      :nomatch -> {text, ""}
    end
  end

  defp domain(host) do
    host = percent_decode(host)

    if Regex.match?(~r/[\x00-\x20#%\/:<>?@\[\\\]^|]/, host), do: raise(ArgumentError, "Invalid URL")

    lower = if String.valid?(host), do: String.downcase(host), else: raise(ArgumentError, "Invalid URL")

    lower =
      if Regex.match?(~r/[^\x00-\x7f]/, lower) do
        case Runlight.Punycode.to_ascii(lower) do
          {:ok, ascii} -> ascii
          :error -> raise ArgumentError, "Invalid URL"
        end
      else
        lower
      end

    ipv4(lower) || lower
  end

  defp percent_decode(text) do
    Regex.replace(~r/%([0-9A-Fa-f]{2})/, text, fn _, hex -> <<String.to_integer(hex, 16)>> end)
  end

  # A host written as an IPv4 address in any form browsers accept, normalised to dotted decimal.
  defp ipv4(host) do
    parts = String.split(host, ".")
    parts = if List.last(parts) == "" and length(parts) > 1, do: Enum.drop(parts, -1), else: parts
    last = List.last(parts)

    cond do
      parts == [] or length(parts) > 4 ->
        nil

      not Regex.match?(~r/\A(0x[0-9a-f]*|[0-9]+)\z/, last) ->
        nil

      true ->
        numbers =
          Enum.map(parts, fn part ->
            cond do
              m = Regex.run(~r/\A0x([0-9a-f]*)\z/, part) ->
                case m do
                  [_, ""] -> 0
                  [_, hex] -> String.to_integer(hex, 16)
                end

              Regex.match?(~r/\A0[0-7]+\z/, part) ->
                String.to_integer(part, 8)

              Regex.match?(~r/\A[0-9]+\z/, part) ->
                String.to_integer(part)

              true ->
                raise ArgumentError, "Invalid URL"
            end
          end)

        {value, numbers} = List.pop_at(numbers, -1)
        if Enum.any?(numbers, &(&1 > 255)), do: raise(ArgumentError, "Invalid URL")
        if value >= Integer.pow(256, 5 - length(parts)), do: raise(ArgumentError, "Invalid URL")

        value =
          numbers
          |> Enum.with_index()
          |> Enum.reduce(value, fn {n, i}, acc -> acc + n * Integer.pow(256, 3 - i) end)

        import Bitwise

        Enum.join([value >>> 24 &&& 255, value >>> 16 &&& 255, value >>> 8 &&& 255, value &&& 255], ".")
    end
  end

  defp path(path) do
    [_ | segments] = String.split(path, "/")
    count = length(segments)

    out =
      segments
      |> Enum.with_index()
      |> Enum.reduce([], fn {segment, i}, out ->
        lower = String.downcase(segment)
        last = i == count - 1

        cond do
          lower in ["..", ".%2e", "%2e.", "%2e%2e"] ->
            out = if out == [], do: [], else: tl(out)
            if last, do: ["" | out], else: out

          lower in [".", "%2e"] ->
            if last, do: ["" | out], else: out

          true ->
            [encode(segment, @path_set) | out]
        end
      end)

    "/" <> (out |> Enum.reverse() |> Enum.join("/"))
  end

  @doc "Percent-encodes C0 controls, DEL, bytes past ASCII, and the extra characters; escapes already there stay."
  @spec encode(String.t(), charlist()) :: String.t()
  def encode(text, extra) do
    text = Runlight.JS.scrub(text)

    for <<c <- text>>, into: "" do
      if c < 0x21 or c > 0x7E or c in extra,
        do: "%" <> (c |> Integer.to_string(16) |> String.pad_leading(2, "0")),
        else: <<c>>
    end
  end

  defimpl String.Chars do
    def to_string(url), do: Runlight.Url.href(url)
  end
end
