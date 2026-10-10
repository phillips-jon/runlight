defmodule Runlight.Safefetch do
  @moduledoc """
  Fetches from addresses that other people's input names, such as the icon
  links on a site's home page or a link domain, and only from the public
  internet (the SDK's safefetch.ts). Only https is fetched, never a private,
  loopback, link-local, or metadata address, and redirects are followed by
  hand under the same rules.

  The default fetcher (`Runlight.Fetch.httpc/2`) resolves the name itself,
  checks every address, and connects to one it checked, so a name that
  answers differently a moment later gets nowhere. The name is also checked
  just before each request, for a fetcher of the app's own that cannot
  choose the address it connects to.
  """

  import Bitwise

  alias Runlight.Http.Response
  alias Runlight.Url

  defp v4(text) do
    parts = String.split(text, ".")

    if length(parts) == 4 and Enum.all?(parts, &(Regex.match?(~r/\A\d{1,3}\z/, &1) and String.to_integer(&1) <= 255)),
      do: Enum.map(parts, &String.to_integer/1)
  end

  defp public_v4?([a, b, c | _]) do
    cond do
      a in [0, 10, 127] or a >= 224 -> false
      a == 100 and b >= 64 and b < 128 -> false
      a == 169 and b == 254 -> false
      a == 172 and b >= 16 and b < 32 -> false
      a == 192 and b == 168 -> false
      a == 192 and b == 0 and c in [0, 2] -> false
      a == 198 and b in [18, 19] -> false
      a == 198 and b == 51 and c == 100 -> false
      a == 203 and b == 0 and c == 113 -> false
      true -> true
    end
  end

  # An IPv6 address as eight 16-bit groups, or nil when it is not one.
  defp v6(text) do
    address = text |> String.replace(~r/^\[|\]$/, "") |> String.split("%") |> hd() |> String.downcase()

    address =
      case Regex.run(~r/(\d{1,3}(?:\.\d{1,3}){3})\z/, address) do
        [_, tail] ->
          case v4(tail) do
            nil ->
              :bad

            [a, b, c, d] ->
              head = binary_part(address, 0, byte_size(address) - byte_size(tail))
              head <> Integer.to_string(a <<< 8 ||| b, 16) <> ":" <> Integer.to_string(c <<< 8 ||| d, 16)
          end

        nil ->
          address
      end

    if address == :bad, do: nil, else: groups(String.downcase(address))
  end

  defp groups(address) do
    halves = String.split(address, "::")

    if length(halves) > 2 do
      nil
    else
      head = if hd(halves) == "", do: [], else: String.split(hd(halves), ":")
      rest = if length(halves) == 2 and Enum.at(halves, 1) != "", do: String.split(Enum.at(halves, 1), ":"), else: []
      missing = 8 - length(head) - length(rest)
      ok = if length(halves) == 1, do: missing == 0, else: missing >= 1

      if ok do
        all = head ++ List.duplicate("0", if(length(halves) == 2, do: missing, else: 0)) ++ rest
        if Enum.all?(all, &Regex.match?(~r/\A[0-9a-f]{1,4}\z/, &1)), do: Enum.map(all, &String.to_integer(&1, 16))
      end
    end
  end

  @doc "Whether an IP address, v4 or v6, is on the public internet. Anything that is not an address is not."
  @spec public_address?(String.t()) :: boolean()
  def public_address?(ip) do
    case v4(ip) do
      nil ->
        case v6(ip) do
          nil -> false
          g -> public_v6?(g)
        end

      four ->
        public_v4?(four)
    end
  end

  defp embedded(hi, lo), do: [hi >>> 8, hi &&& 255, lo >>> 8, lo &&& 255]

  defp public_v6?([g0, g1, g2, g3, g4, g5, g6, g7] = g) do
    cond do
      # IPv4 inside IPv6: mapped (::ffff:0:0/96), the old compatible form (::/96), and NAT64 (64:ff9b::/96).
      Enum.take(g, 5) |> Enum.all?(&(&1 == 0)) and g5 in [0xFFFF, 0] ->
        if g5 == 0 and g6 == 0 and g7 <= 1, do: false, else: public_v4?(embedded(g6, g7))

      g0 == 0x64 and g1 == 0xFF9B and Enum.all?([g2, g3, g4, g5], &(&1 == 0)) ->
        public_v4?(embedded(g6, g7))

      # 6to4 carries an IPv4 address in its second and third groups.
      g0 == 0x2002 ->
        public_v4?(embedded(g1, g2))

      (g0 &&& 0xFE00) == 0xFC00 or (g0 &&& 0xFFC0) == 0xFE80 or (g0 &&& 0xFF00) == 0xFF00 ->
        false

      # Teredo, documentation, and discard prefixes.
      g0 == 0x2001 and g1 in [0, 0xDB8] ->
        false

      g0 == 0x100 and Enum.all?([g1, g2, g3], &(&1 == 0)) ->
        false

      true ->
        true
    end
  end

  defp lookup(name) do
    charlist = String.to_charlist(name)

    addresses =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(charlist, family) do
          {:ok, list} -> Enum.map(list, &(:inet.ntoa(&1) |> to_string()))
          _ -> []
        end
      end)

    if addresses == [], do: :error, else: {:ok, Enum.uniq(addresses)}
  end

  @doc "The public addresses a name resolves to, for setting up DNS records. None where it does not resolve."
  @spec public_addresses(String.t()) :: [String.t()]
  def public_addresses(name) do
    case lookup(name) do
      {:ok, list} -> Enum.filter(list, &public_address?/1)
      :error -> []
    end
  end

  @doc "Whether a name resolves to an address off the public internet. False when it does not resolve."
  @spec resolves_privately?(String.t()) :: boolean()
  def resolves_privately?(name) do
    case lookup(name) do
      {:ok, list} -> Enum.any?(list, &(not public_address?(&1)))
      :error -> false
    end
  end

  @doc false
  # The address to connect to for a name, when every address it has is public.
  @spec checked_address(String.t()) :: {:ok, String.t()} | {:error, :private | :nxdomain}
  def checked_address(name) do
    case lookup(name) do
      {:ok, list} -> if Enum.all?(list, &public_address?/1), do: {:ok, hd(list)}, else: {:error, :private}
      :error -> {:error, :nxdomain}
    end
  end

  @doc """
  Fetches an https URL on the public internet (a GET unless `method:` and
  `body:` say otherwise), following up to `redirects:` redirects that stay
  on it, within `timeout:` milliseconds in all. Only a GET follows
  redirects; anything else comes back with the redirect as it is. Answers
  `{:error, :private}` for an address off it and `{:error, :timeout}` when
  time runs out. A redirect past the last one comes back as it is.
  """
  @spec public_fetch(Runlight.t(), String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def public_fetch(rl, target, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout)

    case Url.parse(target) do
      nil -> {:error, :invalid_url}
      url -> hop(rl, url, opts, deadline, 0)
    end
  end

  # An install on this machine: http://localhost or http://127.0.0.1, with any port.
  @local_install ~r/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?(\/|$)/

  @doc false
  # Whether an address can be another Runlight install's: https, or, with `local`, an install on this machine,
  # which only code can allow (the instance's `:local_installs`).
  @spec install_address?(String.t(), boolean()) :: boolean()
  def install_address?(url, local),
    do: Regex.match?(~r/^https:\/\/[^\/]+/, url) or (local and Regex.match?(@local_install, url))

  @doc false
  # Fetches from another Runlight install, which someone signed in named: a public address as public_fetch/3
  # fetches it, with no redirect followed, so a token sent there goes nowhere else. With the instance's
  # `:local_installs`, an install on this machine is fetched as it is, still without following a redirect.
  @spec install_fetch(Runlight.t(), String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def install_fetch(rl, target, opts) do
    if rl.local_installs and Regex.match?(@local_install, target),
      do: Runlight.fetch(rl, target, Keyword.put(opts, :redirect, :manual)),
      else: public_fetch(rl, target, Keyword.put(opts, :redirects, 0))
  end

  defp redirects(opts),
    do: if(String.upcase(Keyword.get(opts, :method, "GET")) == "GET", do: Keyword.get(opts, :redirects, 0), else: 0)

  defp hop(rl, url, opts, deadline, n) do
    host = url.hostname |> String.replace(~r/^\[|\]$/, "") |> String.downcase()
    left = deadline - System.monotonic_time(:millisecond)

    cond do
      url.protocol != "https:" ->
        {:error, :private}

      (v4(host) != nil or v6(host) != nil) and not public_address?(host) ->
        {:error, :private}

      host == "localhost" or String.ends_with?(host, ".localhost") ->
        {:error, :private}

      v4(host) == nil and v6(host) == nil and resolves_privately?(host) ->
        {:error, :private}

      left <= 0 ->
        {:error, :timeout}

      true ->
        fetch_opts =
          [headers: Keyword.get(opts, :headers, []), redirect: :manual, timeout: left, public: true] ++
            Keyword.take(opts, [:method, :body, :max_bytes, :truncate])

        case Runlight.fetch(rl, Url.href(url), fetch_opts) do
          {:ok, answer} ->
            location = Response.header(answer, "location")

            next = location && Url.parse(location, url)

            if answer.status < 300 or answer.status >= 400 or location == nil or n >= redirects(opts) or
                 next == nil,
               do: {:ok, answer},
               else: hop(rl, next, opts, deadline, n + 1)

          {:error, :timeout} ->
            {:error, :timeout}

          {:error, reason} ->
            if System.monotonic_time(:millisecond) >= deadline, do: {:error, :timeout}, else: {:error, reason}
        end
    end
  end
end
