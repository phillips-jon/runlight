defmodule Runlight.OAuth do
  @moduledoc false
  # Internal. OAuth for the MCP server, so apps that connect only through
  # OAuth (the Claude and ChatGPT web connectors) can reach it (the SDK's
  # oauth.ts). Runlight is both the resource and the authorization server.
  # The token an app gets is an ordinary API token, so it appears in
  # Settings, API and AI, beside the others.

  alias Runlight.Crypto
  alias Runlight.Hash
  alias Runlight.Http.Request
  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.RateLimit
  alias Runlight.SearchParams
  alias Runlight.Store
  alias Runlight.Url

  @code_ms 5 * 60_000
  # An app stored before client ids were signed, which never finished connecting within a day, is removed.
  @unused_client_ms 86_400_000
  @registrations_per_minute 10
  # The longest client id, which carries the app's name and redirect addresses.
  @max_client_id 2048

  @cors [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-headers", "authorization, content-type, mcp-protocol-version"},
    {"access-control-allow-methods", "GET, POST, OPTIONS"}
  ]

  defp base64url(text), do: Base.url_encode64(text, padding: false)

  # The key client ids are signed with, made on first use and kept in the database for every process.
  defp client_key(rl) do
    case Store.setting(rl.store, "oauth-key") do
      nil ->
        made = Hash.random_id(32)
        Store.set_setting(rl.store, "oauth-key", made)
        made

      saved ->
        saved
    end
  end

  # The app a client id names, and where to note that it connected.
  defp client_for(rl, id) do
    cond do
      Regex.match?(~r/\A[a-f0-9]{32}\z/, id) ->
        case Store.setting(rl.store, "oauth-client:#{id}") do
          nil -> nil
          stored -> %{client: JS.parse!(stored), used_key: "oauth-client:#{id}"}
        end

      true ->
        with [_, payload, mac] <- Regex.run(~r/\A([A-Za-z0-9_-]{1,2000})\.([a-f0-9]{64})\z/, id),
             true <- JS.len16(id) <= @max_client_id,
             true <- Crypto.constant_time_equal?(mac, Hash.hmac(client_key(rl), payload)),
             bytes when is_binary(bytes) <- Crypto.from_base64url(payload),
             {:ok, %Object{} = meta} <- JS.parse(JS.decode_utf8(bytes)) do
          used_key = "oauth-used:#{Hash.sha256(id)}"
          used = Store.setting(rl.store, used_key)
          client = JS.obj(name: meta["n"], redirects: meta["r"], createdAt: meta["t"])
          client = if used, do: Object.put(client, "usedAt", JS.number(used)), else: client
          %{client: client, used_key: used_key}
        else
          _ -> nil
        end
    end
  end

  defp esc(value), do: JS.escape_html(value)

  defp json(body, status \\ 200) do
    Response.new(
      JS.stringify(body),
      status,
      [{"content-type", "application/json; charset=utf-8"}, {"cache-control", "no-store"}] ++ @cors
    )
  end

  defp oauth_error(error, description, status \\ 400),
    do: json(JS.obj(error: error, error_description: description), status)

  @doc "base64url of SHA-256, as PKCE's S256 method compares."
  def s256(verifier), do: :crypto.hash(:sha256, verifier) |> base64url()

  # Redirect addresses a client may register: https, or a local app's own loopback address.
  defp allowed_redirect?(value),
    do:
      Regex.match?(~r/^https:\/\/[^\/]+/, value) or
        Regex.match?(~r/^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?\//, value)

  @doc "The URL that a 401 from the MCP endpoint points clients at, to start OAuth."
  def resource_metadata_url(origin, base), do: "#{origin}#{base}/.well-known/oauth-protected-resource"

  @doc "Answers the OAuth paths, or nil for anything else."
  def response(ctx, %Request{} = request, path, %Url{} = url) do
    rl = ctx.rl
    base = ctx.base
    issuer = "#{Url.origin(url)}#{base}"

    well_known =
      String.starts_with?(path, "/.well-known/oauth-") or String.starts_with?(path, "/.well-known/openid-configuration")

    cond do
      request.method == "OPTIONS" and (well_known or String.starts_with?(path, "/oauth/")) ->
        Response.new(nil, 204, @cors)

      String.starts_with?(path, "/.well-known/oauth-protected-resource") ->
        json(
          JS.obj(
            resource: "#{issuer}/mcp",
            authorization_servers: [issuer],
            scopes_supported: ["read", "manage"],
            bearer_methods_supported: ["header"]
          )
        )

      String.starts_with?(path, "/.well-known/oauth-authorization-server") or
          String.starts_with?(path, "/.well-known/openid-configuration") ->
        json(
          JS.obj(
            issuer: issuer,
            authorization_endpoint: "#{issuer}/oauth/authorize",
            token_endpoint: "#{issuer}/oauth/token",
            registration_endpoint: "#{issuer}/oauth/register",
            response_types_supported: ["code"],
            grant_types_supported: ["authorization_code"],
            code_challenge_methods_supported: ["S256"],
            token_endpoint_auth_methods_supported: ["none"],
            scopes_supported: ["read", "manage"]
          )
        )

      path == "/oauth/register" and request.method == "POST" ->
        Runlight.init(rl)
        limit = RateLimit.new(rl.table, :oauth_registrations, @registrations_per_minute)

        if RateLimit.allow?(limit, Runlight.client_ip(rl, request), Runlight.now(rl)) do
          body =
            case Request.json(request),
              do: (
                {:ok, %Object{} = b} -> b
                _ -> nil
              )

          redirects =
            case body && body["redirect_uris"] do
              list when is_list(list) ->
                list |> Enum.map(&JS.string/1) |> Enum.filter(&allowed_redirect?/1) |> Enum.take(10)

              _ ->
                []
            end

          if redirects == [],
            do: oauth_error("invalid_redirect_uri", "Register at least one https redirect address"),
            else: register(rl, JS.string(JS.nullish(body && JS.prop(body, "client_name"), "An app")), redirects)
        else
          oauth_error(
            "invalid_client_metadata",
            "Too many registrations from this address. Wait a minute and try again.",
            429
          )
        end

      path == "/oauth/authorize" and request.method in ["GET", "POST"] ->
        Runlight.init(rl)
        authorize(ctx, request, url)

      path == "/oauth/token" and request.method == "POST" ->
        Runlight.init(rl)
        token(ctx, request)

      true ->
        nil
    end
  end

  defp authorize(ctx, request, url) do
    rl = ctx.rl
    base = ctx.base
    form = if request.method == "POST", do: SearchParams.parse(Request.text(request)), else: Url.search_params(url)
    get = fn name -> SearchParams.get(form, name) end
    client_id = get.("client_id") || ""
    found = client_for(rl, client_id)
    client = found && found.client
    redirect = get.("redirect_uri") || ""

    # Without a known client and one of its own addresses there is nowhere safe to send an answer.
    if client == nil or redirect not in (client["redirects"] || []) do
      page("This app is not registered", "<p>Start connecting again from the app.</p>", 400)
    else
      back = fn params ->
        to = Url.new(redirect)
        query = Enum.reduce(params, Url.search_params(to), fn {k, v}, q -> SearchParams.set(q, k, v) end)
        state = get.("state")
        query = if state not in [nil, ""], do: SearchParams.set(query, "state", state), else: query
        Response.new(nil, 303, [{"location", Url.href(Url.with_params(to, query))}, {"cache-control", "no-store"}])
      end

      # Until an owner has allowed it once, a request it got wrong ends on a page here.
      refuse = fn params ->
        if JS.truthy?(client["usedAt"]) do
          back.(params)
        else
          said =
            Enum.find_value(params, fn {k, v} -> if k == "error_description", do: v end) ||
              Enum.find_value(params, fn {k, v} -> if k == "error", do: v end)

          page(
            "This app asked in a way Runlight does not support",
            "<p>#{esc(client["name"])} sent #{esc(said)}. Start connecting again from the app.</p>",
            400
          )
        end
      end

      challenge = get.("code_challenge") || ""
      manage = "manage" in String.split(get.("scope") || "", ~r/\s+/u)

      cond do
        get.("response_type") != "code" ->
          refuse.([{"error", "unsupported_response_type"}])

        get.("code_challenge_method") != "S256" or not Regex.match?(~r/\A[A-Za-z0-9_-]{43,128}\z/, challenge) ->
          refuse.([{"error", "invalid_request"}, {"error_description", "PKCE with S256 is required"}])

        not ctx.is_owner.(request) ->
          cond do
            # Someone signed in who may only read would be sent to sign in again and again.
            ctx.is_reader && ctx.is_reader.(request) ->
              page(
                "Ask an owner to connect this",
                "<p>You are signed in as a viewer, and only an owner of this Runlight can connect #{esc(client["name"])}.</p>",
                403
              )

            ctx.sign_in ->
              # The site stays, since on the way in it only says which one to offer first.
              here = "#{url.pathname}?#{SearchParams.to_string(Enum.reject(form, fn {k, _} -> k == "decision" end))}"

              Response.new(nil, 303, [
                {"location", "#{ctx.sign_in}?next=#{JS.encode_uri_component(here)}"},
                {"cache-control", "no-store"}
              ])

            true ->
              page(
                "Sign in first",
                ~s(<p>Open your Runlight dashboard at <a href="#{esc(if base == "", do: "/", else: base)}">#{esc(Url.host(url) <> if(base == "", do: "/", else: base))}</a> and sign in, then connect #{esc(client["name"])} again.</p>),
                401
              )
          end

        request.method == "GET" ->
          consent(rl, base, client, form, redirect, manage)

        true ->
          # The consent form posts here from this page only; a form from another site is refused.
          origin = Request.header(request, "origin")
          site = get.("site") || ""

          cond do
            origin not in [nil, ""] and origin != Url.origin(url) ->
              page("This request came from another site", "<p>Start connecting again from the app.</p>", 403)

            get.("decision") != "allow" ->
              back.([{"error", "access_denied"}])

            site != "" and Runlight.site(rl, site) == nil ->
              back.([{"error", "invalid_request"}, {"error_description", "Unknown site"}])

            manage and (site == "" or Runlight.remote(rl, site) != nil) ->
              back.([{"error", "invalid_request"}, {"error_description", "Pick the site to manage"}])

            true ->
              code = Hash.random_id(32)
              by = if ctx.account_of, do: ctx.account_of.(request)

              grant =
                JS.obj(
                  client: client_id,
                  redirect: redirect,
                  challenge: challenge,
                  site: site,
                  scope: if(manage, do: "manage", else: "read"),
                  expires: Runlight.now(rl) + @code_ms,
                  by: if(by, do: by, else: :undefined)
                )

              Store.set_setting(rl.store, "oauth-code:#{Hash.sha256(code)}", JS.stringify(grant))
              back.([{"code", code}])
          end
      end
    end
  end

  defp consent(rl, base, client, form, redirect, manage) do
    hidden =
      ~w(response_type client_id redirect_uri code_challenge code_challenge_method state scope resource)
      |> Enum.map_join(fn k ->
        case SearchParams.get(form, k) do
          nil -> ""
          v -> ~s(<input type="hidden" name="#{k}" value="#{esc(v)}">)
        end
      end)

    name = esc(client["name"])
    # The app names itself, so the page also shows where the answer goes, which it cannot fake.
    sends_to =
      ~s(<p class="note">Allowing sends you back to <strong>#{esc(Url.host(Url.new(redirect)))}</strong>. Only allow it if you started connecting there.</p>)

    if manage do
      # Changing settings is for one site at a time, so there is no "every site" here.
      sites = Enum.filter(Runlight.sites(rl), &(Runlight.remote(rl, &1["id"]) == nil))
      wanted = SearchParams.get(form, "site") || ""

      choices =
        Enum.map_join(sites, fn s ->
          ~s(<option value="#{esc(s["id"])}"#{if s["id"] == wanted, do: " selected", else: ""}>#{esc(s["name"])}</option>)
        end)

      page(
        "Connect #{name}",
        """
        <p><strong>#{name}</strong> wants to show this site’s stats and change its settings, so you can manage it from there.</p>
        <p>It will be able to change goals, funnels, short links, link domains, email reports, and share links for the site you pick, along with its name, timezone, and retention. It cannot read other sites, add people, make tokens, or change how email is sent.</p>
        #{sends_to}
        <form method="post" action="#{esc(base)}/oauth/authorize">#{hidden}
        <label>Site<select name="site">#{choices}</select></label>
        <p class="note">Its token appears in Settings, API and AI, where deleting it disconnects #{name}.</p>
        <div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button><button type="submit" name="decision" value="allow">Allow</button></div></form>\
        """
      )
    else
      sites = Runlight.sites(rl)
      options = Enum.map_join(sites, fn s -> ~s(<option value="#{esc(s["id"])}">#{esc(s["name"])} only</option>) end)

      page(
        "Connect #{name}",
        """
        <p><strong>#{name}</strong> wants to read your Runlight stats so it can answer questions about them. It will be able to read and never to change anything.</p>
        #{sends_to}
        <form method="post" action="#{esc(base)}/oauth/authorize">#{hidden}
        <label>Which sites it can read<select name="site"><option value="">Every site</option>#{if length(sites) > 1, do: options, else: ""}</select></label>
        <p class="note">Its token appears in Settings, API and AI, where deleting it disconnects the app.</p>
        <div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button><button type="submit" name="decision" value="allow">Allow</button></div></form>\
        """
      )
    end
  end

  defp token(ctx, request) do
    _rl = ctx.rl
    type = (Request.header(request, "content-type") || "") |> String.split(";") |> hd() |> JS.trim()

    form =
      if type == "application/json" do
        case Request.json(request) do
          {:ok, %Object{} = body} -> Enum.map(Object.to_list(body), fn {k, v} -> {k, JS.string(v)} end)
          _ -> []
        end
      else
        SearchParams.parse(Request.text(request))
      end

    get = fn name -> SearchParams.get(form, name) end

    if get.("grant_type") != "authorization_code",
      do: oauth_error("unsupported_grant_type", "Only authorization_code is supported"),
      else: exchange(ctx, request, get)
  end

  defp exchange(ctx, _request, get) do
    rl = ctx.rl
    key = "oauth-code:#{Hash.sha256(get.("code") || "")}"
    stored = Store.setting(rl.store, key)
    # A code works once: it is gone before anything else is checked.
    if stored, do: Store.set_setting(rl.store, key, nil)
    grant = stored && JS.parse!(stored)

    cond do
      grant == nil or grant["expires"] < Runlight.now(rl) ->
        oauth_error("invalid_grant", "The code has expired or was already used")

      grant["client"] != get.("client_id") or grant["redirect"] != get.("redirect_uri") ->
        oauth_error("invalid_grant", "The code was issued to another app")

      s256(get.("code_verifier") || "") != grant["challenge"] ->
        oauth_error("invalid_grant", "The code verifier does not match")

      true ->
        # The first row an app gets here: it has connected, so a request it gets wrong may go back to it.
        found = client_for(rl, grant["client"])
        client = (found && found.client) || Object.new()

        if found && not JS.truthy?(found.client["usedAt"]) do
          if String.starts_with?(found.used_key, "oauth-client:"),
            do:
              Store.set_setting(
                rl.store,
                found.used_key,
                JS.stringify(Object.put(found.client, "usedAt", Runlight.now(rl)))
              ),
            else: Store.set_setting(rl.store, found.used_key, JS.string(Runlight.now(rl)))
        end

        secret = "rl_" <> Hash.random_id(20)
        scope = if grant["scope"] == "manage", do: "manage", else: "read"

        row =
          JS.obj(
            id: Hash.random_id(),
            name: JS.slice("#{client["name"] || "An app"} (OAuth)", 0, 100),
            site: grant["site"],
            scope: scope,
            hash: Hash.sha256(secret),
            hint: JS.slice(secret, -4),
            createdAt: Runlight.now(rl),
            lastUsedAt: nil
          )

        Store.insert_token(rl.store, row)

        # Someone removed, or no longer an owner, between allowing the app and its swapping the code gets nothing.
        if (JS.truthy?(grant["by"]) and ctx.token_made) && not ctx.token_made.(row, grant["by"]) do
          Store.delete_token(rl.store, row["id"])
          oauth_error("invalid_grant", "Whoever allowed this app can no longer connect it")
        else
          # A hub's own address, from where it asked to be sent back, so the picker only ever sends choices there.
          if scope == "manage",
            do: Store.set_setting(rl.store, "token-origin:#{row["id"]}", Url.origin(Url.new(grant["redirect"])))

          out = JS.obj(access_token: secret, token_type: "Bearer", scope: scope)
          json(if(JS.truthy?(grant["site"]), do: Object.put(out, "site", grant["site"]), else: out))
        end
    end
  end

  # Registers a client by signing its name and addresses into its id, so nothing is stored until an owner allows it.
  defp register(rl, name, redirects) do
    now = Runlight.now(rl)

    # Apps stored before ids were signed, which never connected, and codes nobody exchanged are cleared away.
    for %{key: key, value: value} <- Store.settings_starting_with(rl.store, "oauth-client:") do
      client = JS.parse!(value)

      if not JS.truthy?(client["usedAt"]) and now - client["createdAt"] >= @unused_client_ms,
        do: Store.set_setting(rl.store, key, nil)
    end

    for %{key: key, value: value} <- Store.settings_starting_with(rl.store, "oauth-code:") do
      if JS.number(JS.nullish(JS.parse!(value)["expires"], 0)) < now, do: Store.set_setting(rl.store, key, nil)
    end

    name = JS.or_else(name |> JS.trim() |> JS.slice(0, 80), "An app")
    payload = base64url(JS.stringify(JS.obj(n: name, r: redirects, t: now)))
    id = "#{payload}.#{Hash.hmac(client_key(rl), payload)}"

    if JS.len16(id) > @max_client_id do
      oauth_error("invalid_client_metadata", "Register fewer or shorter redirect addresses")
    else
      json(
        JS.obj(
          client_id: id,
          client_name: name,
          redirect_uris: redirects,
          token_endpoint_auth_method: "none",
          grant_types: ["authorization_code"],
          response_types: ["code"]
        ),
        201
      )
    end
  end

  defp page(title, body, status \\ 200) do
    Response.new(
      ~s(<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>#{title} | Runlight</title>\n) <>
        ~s|<style>:root{color-scheme:light dark;--page:#f4f4f5;--card:#fff;--ink:#111827;--muted:#4b5563;--line:#e5e7eb}@media (prefers-color-scheme:dark){:root{--page:#09090b;--card:#141417;--ink:#fafafa;--muted:#a1a1aa;--line:#27272a}}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--page);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}main{width:min(440px,calc(100% - 32px));padding:28px;background:var(--card);border:1px solid var(--line);border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 16px;color:var(--muted)}p strong{color:var(--ink)}a{color:inherit}label{display:block;margin:0 0 14px;font-size:13px;font-weight:600}select{display:block;width:100%;height:40px;margin-top:6px;padding:0 36px 0 12px;border:1px solid var(--line);border-radius:8px;background:var(--card) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4 6l4 4 4-4' fill='none' stroke='%238a8a93' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") right 12px center/14px no-repeat;color:var(--ink);font:inherit;font-weight:400;appearance:none;cursor:pointer}.note{font-size:13px}.buttons{display:flex;justify-content:flex-end;gap:8px}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:var(--ink);color:var(--card);font:inherit;font-weight:600;cursor:pointer}button.ghost{background:none;color:var(--ink);border:1px solid var(--line)}</style></head><body><main><h1>#{title}</h1>#{body}</main></body></html>|,
      status,
      [
        {"content-type", "text/html; charset=utf-8"},
        {"cache-control", "no-store"},
        # No form-action rule: browsers apply it to the redirect back to the app after Allow.
        {"content-security-policy",
         "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; frame-ancestors 'none'"},
        {"x-frame-options", "DENY"},
        # same-origin, not no-referrer: under no-referrer a form post carries Origin: null, which the consent check
        # refuses.
        {"referrer-policy", "same-origin"}
      ]
    )
  end
end
