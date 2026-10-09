defmodule Runlight.Links do
  @moduledoc """
  Short links: create, change, delete, and import, with the rules every route
  shares (the SDK's links.ts). A link is a JavaScript object: id, site,
  domain ("" for the app's own), slug, name, url, createdAt, and updatedAt.
  """

  alias Runlight.Hash
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.LinkError
  alias Runlight.Sources
  alias Runlight.Store
  alias Runlight.Url

  @alphabet ~c"abcdefghijkmnpqrstuvwxyz23456789"

  @doc "Whether a slug may be used: letters, digits, dashes, and underscores, up to 100, starting with a letter or digit."
  def slug?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,99}\z/, value)

  @doc "Six characters from an alphabet without look-alikes (no 0/o, 1/l)."
  def random_slug do
    for <<b <- :crypto.strong_rand_bytes(6)>>, into: "", do: <<Enum.at(@alphabet, rem(b, length(@alphabet)))>>
  end

  defp clean_url(value) do
    text = value |> JS.nullish("") |> JS.string() |> JS.trim()

    url =
      Url.parse(text) ||
        raise(LinkError, message: "The destination must be a full URL, starting with https://", code: "link_url")

    if url.protocol not in ["https:", "http:"],
      do: raise(LinkError, message: "The destination must start with http:// or https://", code: "link_protocol")

    if JS.len16(text) > 2000,
      do: raise(LinkError, message: "The destination is longer than 2,000 characters", code: "link_long")

    Url.href(url)
  end

  defp default_name(url) do
    u = Url.new(url)
    JS.slice("#{Sources.strip_www(u.hostname)}#{if u.pathname == "/", do: "", else: u.pathname}", 0, 100)
  end

  defp domain_for(rl, site, value) do
    domain = value |> JS.nullish("") |> JS.string() |> JS.trim() |> Sources.strip_www()

    if domain == "" do
      ""
    else
      known = Store.link_domains(rl.store)

      unless Enum.any?(known, &(&1["domain"] == domain and &1["site"] == site)),
        do:
          raise(LinkError,
            message: "Add #{domain} as a link domain in Settings first",
            code: "link_domain",
            params: %{"domain" => domain}
          )

      domain
    end
  end

  # Slugs are unique across every domain, so a link can always fall back to the app's own path.
  defp free_slug(rl, wanted, except \\ nil) do
    if wanted not in [nil, ""] do
      unless slug?(wanted),
        do:
          raise(LinkError, message: "A slug is letters, digits, dashes, and underscores, up to 100", code: "link_slug")

      taken = Store.link_by_slug(rl.store, wanted)

      if taken && taken["id"] != except,
        do: raise(LinkError, message: "/#{wanted} is already taken", code: "link_taken", params: %{"slug" => wanted})

      wanted
    else
      Enum.find_value(1..8, fn _ ->
        slug = random_slug()
        if Store.link_by_slug(rl.store, slug) == nil, do: slug
      end) || raise(LinkError, message: "Could not find a free slug; try again", code: "link_no_slug")
    end
  end

  @doc "Makes a link for a site from `%{\"url\", \"name\", \"slug\", \"domain\"}` (the last three optional)."
  @spec create(Runlight.t(), String.t(), map()) :: Object.t()
  def create(rl, site, input) do
    Runlight.init(rl)
    url = clean_url(input["url"])
    domain = domain_for(rl, site, input["domain"])
    slug = free_slug(rl, if(is_binary(input["slug"]), do: JS.trim(input["slug"]), else: nil))
    now = Runlight.now(rl)
    name = if is_binary(input["name"]), do: JS.trim(input["name"]), else: ""
    name = JS.slice(if(name == "", do: default_name(url), else: name), 0, 100)

    link =
      JS.obj(
        id: Hash.random_id(),
        site: site,
        domain: domain,
        slug: slug,
        name: name,
        url: url,
        createdAt: now,
        updatedAt: now
      )

    Store.insert_link(rl.store, link)
    link
  end

  @doc "Changes a link: any of url, name, slug, and domain, the others as they were."
  @spec update(Runlight.t(), String.t(), map()) :: Object.t()
  def update(rl, id, input) do
    Runlight.init(rl)
    link = Store.link_by_id(rl.store, id) || raise(Runlight.RangeError, message: "Unknown link")
    next = link
    next = if input["url"] != nil, do: Object.put(next, "url", clean_url(input["url"])), else: next

    next =
      if input["name"] != nil do
        name = input["name"] |> JS.string() |> JS.trim() |> JS.slice(0, 100)
        Object.put(next, "name", if(name == "", do: default_name(next["url"]), else: name))
      else
        next
      end

    # Keeping a link's domain needs no check, even while that domain is removed.
    next =
      if input["domain"] != nil and Sources.strip_www(JS.trim(input["domain"])) != link["domain"],
        do: Object.put(next, "domain", domain_for(rl, link["site"], input["domain"])),
        else: next

    next =
      if input["slug"] != nil,
        do: Object.put(next, "slug", free_slug(rl, JS.trim(input["slug"]), link["id"])),
        else: next

    next = Object.put(next, "updatedAt", Runlight.now(rl))
    Store.update_link(rl.store, next)
    next
  end

  @doc "Deletes a link; its clicks stay in the history."
  @spec remove(Runlight.t(), String.t()) :: :ok
  def remove(rl, id) do
    Runlight.init(rl)
    if Store.link_by_id(rl.store, id) == nil, do: raise(Runlight.RangeError, message: "Unknown link")
    Store.delete_link(rl.store, id, Runlight.now(rl))
  end

  @doc """
  Creates many links at once, as from a CSV. Rows that fail are reported
  with their reason and the rest go in. Headers match the Umami fork's
  export: name or link_name, url or destination_url, slug or link_slug,
  domain or tracking_domain.
  """
  @spec import(Runlight.t(), String.t(), [Object.t()]) :: Object.t()
  def import(rl, site, rows) do
    {created, failed} =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce({0, []}, fn {raw, i}, {created, failed} ->
        pick = fn keys ->
          Enum.find_value(keys, fn key ->
            value = JS.prop(raw, key)
            if is_binary(value) and JS.trim(value) != "", do: JS.trim(value)
          end)
        end

        try do
          create(rl, site, %{
            "url" => pick.(["url", "destination_url"]) || "",
            "name" => pick.(["name", "link_name"]),
            "slug" => pick.(["slug", "link_slug"]),
            "domain" => pick.(["domain", "tracking_domain"])
          })

          {created + 1, failed}
        rescue
          # A bad row is reported and skipped; a failing database stops the whole import.
          error in LinkError ->
            {created, failed ++ [JS.obj(row: i, reason: error.message, code: error.code, params: JS.obj(error.params))]}
        end
      end)

    JS.obj(created: created, failed: failed)
  end
end
