defmodule Runlight.Connect do
  @moduledoc false
  # Internal. Connecting another Runlight to this one (a hub) without copying
  # a token (the SDK's connect.ts): this server registers itself with the
  # install's OAuth server, sends the owner to that install's consent page,
  # and on the way back swaps the code for a manage token, limited there to
  # the one site the owner picked.

  alias Runlight.ConnectError
  alias Runlight.Hash
  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Safefetch
  alias Runlight.SearchParams
  alias Runlight.Store
  alias Runlight.Url

  @pending_ms 15 * 60_000
  # The most an install's answer while connecting may weigh; a real one is under a kilobyte.
  @max_bytes 64 * 1024

  @doc "The install's address as its dashboard is, without a trailing slash."
  @spec install_url(term(), boolean()) :: String.t()
  def install_url(value, local \\ false) do
    url = value |> JS.nullish("") |> JS.string() |> JS.trim() |> String.replace(~r/\/+\z/, "")

    # The pattern says which addresses are allowed; the parser, that it is an address at all ("https://[" is not).
    unless Safefetch.install_address?(url, local) and
             Url.parse(url) != nil,
           do:
             raise(ConnectError, message: "Enter the install's address, like https://example.com/runlight", code: "url")

    url
  end

  defp host(url), do: Url.host(Url.new(url))

  defp s256(verifier), do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  # An answer read no further than one byte past the cap, so one past it is known to be too long and taken as none.
  defp json(response) when byte_size(response.body) > @max_bytes, do: nil

  defp json(response) do
    case Response.json(response) do
      {:ok, %Object{} = o} -> o
      _ -> nil
    end
  end

  defp ask(rl, url, opts),
    do: Safefetch.install_fetch(rl, url, opts ++ [max_bytes: @max_bytes + 1, truncate: true])

  # Attempts nobody came back from are removed, so they do not pile up in settings.
  defp clear_expired(rl) do
    for %{key: key, value: value} <- Store.settings_starting_with(rl.store, "connect:") do
      if pending_from(value, Runlight.now(rl)) == nil, do: Store.set_setting(rl.store, key, nil)
    end
  end

  # A saved attempt, or nil when it cannot be read or has no time it runs out, which counts as expired.
  defp pending_from(value, now) do
    with %Object{} = pending <- JS.parse_or(value || "", nil),
         expires when is_number(expires) and expires >= now <- pending["expires"] do
      pending
    else
      _ -> nil
    end
  end

  @doc "Starts connecting: answers the address of the install's consent page."
  @spec start_connect(Runlight.t(), term(), String.t(), String.t()) :: String.t()
  def start_connect(rl, input, back, site \\ "") do
    url = install_url(input, rl.local_installs)

    meta_answer =
      case ask(rl, "#{url}/.well-known/oauth-authorization-server", timeout: 10_000) do
        {:ok, answer} ->
          answer

        {:error, _} ->
          raise ConnectError, message: "Could not reach #{url}", code: "unreachable", params: %{"host" => host(url)}
      end

    meta = if Response.ok?(meta_answer), do: json(meta_answer)
    endpoint = fn key -> meta && JS.prop(meta, key) end

    unless Enum.all?(["authorization_endpoint", "token_endpoint", "registration_endpoint"], &JS.truthy?(endpoint.(&1))),
      do:
        raise(ConnectError,
          message: "#{url} did not answer like a Runlight install",
          code: "not_runlight",
          params: %{"url" => url}
        )

    # Its endpoints must be its own, so an address cannot steer this server into requests elsewhere.
    own = fn value ->
      case is_binary(value) && Url.parse(value) do
        %Url{} = parsed -> Url.origin(parsed) == Url.origin(Url.new(url))
        _ -> false
      end
    end

    unless Enum.all?(["authorization_endpoint", "token_endpoint", "registration_endpoint"], &own.(endpoint.(&1))),
      do:
        raise(ConnectError,
          message: "#{url} named endpoints on another address",
          code: "endpoints",
          params: %{"url" => url}
        )

    scopes = endpoint.("scopes_supported")

    unless is_list(scopes) and "manage" in scopes,
      do:
        raise(ConnectError,
          message: "#{url} runs an older Runlight. Update it, or connect it with an API token from its Settings.",
          code: "old",
          params: %{"url" => url}
        )

    registered =
      case ask(rl, meta["registration_endpoint"],
             method: "POST",
             headers: [{"content-type", "application/json"}],
             body: JS.stringify(JS.obj(client_name: "Runlight at #{host(back)}", redirect_uris: [back])),
             timeout: 10_000
           ) do
        {:ok, answer} ->
          answer

        {:error, _} ->
          raise ConnectError, message: "Could not reach #{url}", code: "unreachable", params: %{"host" => host(url)}
      end

    client = json(registered)
    client_id = client && JS.prop(client, "client_id")

    unless Response.ok?(registered) and JS.truthy?(client_id) do
      # Say why, in the install's own words when it gives them.
      description = client && JS.prop(client, "error_description")

      reason =
        cond do
          JS.truthy?(description) -> JS.slice(JS.string(description), 0, 200) <> "."
          registered.status == 400 -> "This server's address must use https."
          true -> "It answered #{registered.status}."
        end

      raise ConnectError,
        message: "#{url} would not let this server connect. #{reason}",
        code: "register",
        params: %{"url" => url, "reason" => reason}
    end

    clear_expired(rl)
    state = Hash.random_id(16)
    verifier = Hash.random_id(32) <> Hash.random_id(32)

    pending =
      JS.obj(
        url: url,
        client: client_id,
        verifier: verifier,
        redirect: back,
        token: meta["token_endpoint"],
        expires: Runlight.now(rl) + @pending_ms
      )

    Store.set_setting(rl.store, "connect:#{state}", JS.stringify(pending))

    params =
      [
        {"response_type", "code"},
        {"client_id", JS.string(client_id)},
        {"redirect_uri", back},
        {"code_challenge", s256(verifier)},
        {"code_challenge_method", "S256"},
        {"scope", "manage"},
        {"state", state}
      ] ++
        if(site != "", do: [{"site", site}], else: [])

    meta["authorization_endpoint"] |> Url.new() |> Url.put_search(SearchParams.to_string(params)) |> Url.href()
  end

  @doc "Finishes connecting when the owner comes back from the consent page. Answers the site's id here."
  @spec finish_connect(Runlight.t(), SearchParams.t()) :: String.t()
  def finish_connect(rl, params) do
    state = SearchParams.get(params, "state") || ""
    key = "connect:#{state}"
    stored = if Regex.match?(~r/\A[a-f0-9]{32}\z/, state), do: Store.setting(rl.store, key)
    # Each attempt works once.
    if stored, do: Store.set_setting(rl.store, key, nil)
    pending = if stored not in [nil, ""], do: pending_from(stored, Runlight.now(rl))

    if pending == nil,
      do:
        raise(ConnectError, message: "That connection took too long or was already used. Start again.", code: "expired")

    error = SearchParams.get(params, "error")
    if error == "access_denied", do: raise(ConnectError, message: "The connection was not allowed.", code: "denied")

    if JS.truthy?(error),
      do: raise(ConnectError, message: SearchParams.get(params, "error_description") || error, code: "refused")

    form =
      SearchParams.to_string([
        {"grant_type", "authorization_code"},
        {"code", SearchParams.get(params, "code") || ""},
        {"client_id", JS.string(pending["client"])},
        {"redirect_uri", JS.string(pending["redirect"])},
        {"code_verifier", JS.string(pending["verifier"])}
      ])

    granted =
      case ask(rl, pending["token"],
             method: "POST",
             headers: [{"content-type", "application/x-www-form-urlencoded"}],
             body: form,
             timeout: 10_000
           ) do
        {:ok, answer} -> if Response.ok?(answer), do: json(answer)
        {:error, _} -> nil
      end

    token = granted && JS.prop(granted, "access_token")

    unless JS.truthy?(token),
      do:
        raise(ConnectError,
          message: "#{host(pending["url"])} did not give this server a token. Start again.",
          code: "token"
        )

    site =
      Runlight.add_site(rl, JS.obj(remote: JS.obj(url: pending["url"], token: token, site: JS.prop(granted, "site"))))

    site["id"]
  end
end
