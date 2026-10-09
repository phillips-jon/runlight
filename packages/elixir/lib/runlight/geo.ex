defmodule Runlight.Geo do
  @moduledoc """
  Where a visitor is, from a hosting platform's headers or a database lookup.

  A location is `%{country: "CA", region: "CA-ON", city: "Toronto"}`: the
  country ISO 3166-1 alpha-2 in upper case, the region ISO 3166-2. The
  instance's `:geo` option is a lookup, a function of the client's address
  that answers a map with any of those keys or nil, such as one
  `file_lookup/1` makes from an MMDB file (MaxMind's GeoLite2 City, or
  DB-IP's free city database). Headers from Vercel, Cloudflare, or Netlify
  always win over it.
  """

  alias Runlight.Http.Headers
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Mmdb

  @empty %{country: "", region: "", city: ""}

  defp decode(nil), do: ""
  defp decode(""), do: ""
  defp decode(value), do: JS.trim(JS.decode_uri_component(value) || value)

  defp text(nil), do: ""
  defp text(:undefined), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(_), do: throw(:not_a_string)

  defp clean(location) do
    country = location |> Map.get(:country) |> text() |> JS.upper() |> JS.slice(0, 2)
    country = if Regex.match?(~r/\A[A-Z]{2}\z/, country) and country not in ["XX", "T1"], do: country, else: ""
    # A code ("CA", "US-CA") is kept as ISO 3166-2; a name from a database
    # that has no codes ("California") is kept readable, as "US-California".
    raw = location |> Map.get(:region) |> text() |> JS.trim()

    region =
      if Regex.match?(~r/\A([A-Za-z]{2}-)?[A-Za-z0-9]{1,3}\z/, raw), do: JS.upper(raw), else: JS.slice(raw, 0, 80)

    region =
      if region != "" and not Regex.match?(~r/^[A-Z]{2}-/, region) and country != "",
        do: "#{country}-#{region}",
        else: region

    region = if country == "", do: "", else: region
    city = if country != "", do: location |> Map.get(:city) |> text() |> JS.slice(0, 100), else: ""
    %{country: country, region: region, city: city}
  end

  @doc false
  # Location from the headers a hosting platform adds, if any.
  @spec location_from_headers(Headers.t()) :: map() | nil
  def location_from_headers(headers) do
    vercel = Headers.get(headers, "x-vercel-ip-country")
    cloudflare = Headers.get(headers, "cf-ipcountry")
    netlify = Headers.get(headers, "x-nf-geo")

    cond do
      vercel not in [nil, ""] ->
        clean(%{
          country: vercel,
          region: decode(Headers.get(headers, "x-vercel-ip-country-region")),
          city: decode(Headers.get(headers, "x-vercel-ip-city"))
        })

      cloudflare not in [nil, ""] ->
        clean(%{
          country: cloudflare,
          region: decode(Headers.get(headers, "cf-region-code")),
          city: decode(Headers.get(headers, "cf-ipcity"))
        })

      netlify not in [nil, ""] ->
        try do
          with {:ok, bytes} <- atob(netlify),
               {:ok, geo} <- JS.parse(latin1(bytes)),
               false <- geo == nil do
            clean(%{
              country: field(field(geo, "country"), "code"),
              region: field(field(geo, "subdivision"), "code"),
              city: field(geo, "city")
            })
          else
            _ -> nil
          end
        catch
          :not_a_string -> nil
        end

      true ->
        nil
    end
  end

  defp field(%Object{} = o, key), do: Object.get(o, key)
  defp field(_, _), do: nil

  # atob(): forgiving base64 to bytes.
  defp atob(text) do
    text = String.replace(text, ~r/[\t\n\f\r ]/, "")
    text = if rem(byte_size(text), 4) == 0, do: String.replace(text, ~r/={1,2}\z/, ""), else: text

    if rem(byte_size(text), 4) == 1 or Regex.match?(~r/[^A-Za-z0-9+\/]/, text) do
      :error
    else
      Base.decode64(text, padding: false)
    end
  end

  # Each byte one character, as atob's string holds them.
  defp latin1(bytes), do: :unicode.characters_to_binary(bytes, :latin1, :utf8)

  @doc false
  # The visitor's location: the platform's headers, else the lookup, else nothing.
  @spec locate(Headers.t(), String.t(), (String.t() -> map() | nil) | nil) :: map()
  def locate(headers, ip, lookup \\ nil) do
    from_headers = location_from_headers(headers)

    cond do
      from_headers != nil and from_headers.country != "" ->
        from_headers

      lookup != nil and ip != "" ->
        try do
          case lookup.(ip) do
            found when is_map(found) -> clean(atomize(found))
            _ -> @empty
          end
        rescue
          # A broken lookup must never lose the event.
          _ -> @empty
        catch
          _, _ -> @empty
        end

      true ->
        @empty
    end
  end

  defp atomize(found) do
    Map.new([:country, :region, :city], fn key -> {key, Map.get(found, key, Map.get(found, Atom.to_string(key)))} end)
  end

  @doc """
  A lookup answering from an MMDB reader. DB-IP's records follow MaxMind's
  city layout, with names but no subdivision codes; a city loses the district
  DB-IP adds in brackets, as in "Toronto (Old Toronto)".
  """
  @spec lookup_from(Mmdb.t()) :: (String.t() -> map() | nil)
  def lookup_from(%Mmdb{} = reader) do
    fn ip ->
      found =
        try do
          Mmdb.get(reader, ip)
        rescue
          _ -> nil
        end

      country = at(found, ["country", "iso_code"])

      if country in [nil, "", false, 0] do
        nil
      else
        sub = at(found, ["subdivisions", 0])
        city = at(found, ["city", "names", "en"]) || ""

        %{
          country: country,
          region: at(sub, ["iso_code"]) || at(sub, ["names", "en"]) || "",
          city: if(is_binary(city), do: city_name(city), else: city)
        }
      end
    end
  end

  @doc "A lookup from an MMDB file the owner supplies, read into memory once."
  @spec file_lookup(Path.t()) :: (String.t() -> map() | nil)
  def file_lookup(path), do: path |> Mmdb.open() |> lookup_from()

  @doc "A city as people say it, without a trailing bracketed district."
  @spec city_name(String.t()) :: String.t()
  def city_name(name) do
    name
    |> JS.scrub()
    |> then(
      &Regex.replace(
        ~r/[\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]*\([^)]*\)[\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]*\z/u,
        &1,
        ""
      )
    )
    |> JS.trim()
  end

  defp at(value, []), do: value
  defp at(map, [key | rest]) when is_map(map) and is_binary(key), do: if(Map.has_key?(map, key), do: at(map[key], rest))

  defp at(list, [i | rest]) when is_list(list) and is_integer(i),
    do: if(i < length(list), do: at(Enum.at(list, i), rest))

  defp at(_, _), do: nil
end
