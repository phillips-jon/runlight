# frozen_string_literal: true

require "base64"
require "openssl"

module Runlight
  # Connecting another Runlight to this one (a hub) without copying a token:
  # this server registers itself with the install's OAuth server, sends the
  # owner to that install's consent page, and on the way back swaps the code
  # for a manage token, limited there to the one site the owner picked.
  #
  # A pending attempt is kept in settings as `connect:<state>`: the install's `url`, the `client` id it gave,
  # the PKCE `verifier`, the `redirect` address, its `token` endpoint, and when it `expires`.
  module Connect
    PENDING_MS = 15 * 60_000
    private_constant :PENDING_MS

    module_function

    # The install's address as its dashboard is, without a trailing slash.
    def install_url(value)
      url = Js.trim(Js.string(value.nil? ? "" : value)).sub(%r{/+\z}, "")
      # The pattern says which addresses are allowed; the parser, that it is an address at all ("https://[" is not).
      unless url.match?(%r{\Ahttps://[^/]+|\Ahttp://(localhost|127\.0\.0\.1)(:\d+)?(/|\z)}) && !Http::Url.parse(url).nil?
        raise ConnectError.new("Enter the install's address, like https://example.com/runlight", "url")
      end

      url
    end

    # A saved attempt, or nil when it cannot be read or has no time it runs out, which counts as expired.
    def pending_from(value, now)
      pending = value.nil? ? nil : Json.try_decode(value)
      return nil unless pending.is_a?(Hash)

      expires = pending["expires"]
      (expires.is_a?(Integer) || expires.is_a?(Float)) && expires >= now ? pending : nil
    end

    # Attempts nobody came back from are removed, so they do not pile up in settings.
    def clear_expired(runlight)
      runlight.store.settings_starting_with("connect:").each do |row|
        runlight.store.set_setting(row["key"], nil) if pending_from(row["value"], runlight.now).nil?
      end
    end

    # The PKCE challenge for a verifier: SHA-256, base64url without padding (oauth.ts's s256).
    def s256(verifier)
      Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(verifier), padding: false)
    end

    # A JSON body, or nil when it is not JSON, as `answer.json().catch(() => null)`.
    def json(answer)
      ok, value = Js.parse_json(answer.text)
      ok ? value : nil
    end

    # Starts connecting: returns the address of the install's consent page.
    def start_connect(runlight, input, back, site = "")
      url = install_url(input)
      host = Http::Url.new(url).host
      begin
        answer = Safefetch.owner_fetch("#{url}/.well-known/oauth-authorization-server", { "timeoutMs" => 10_000 }, runlight.fetcher)
      rescue StandardError
        raise ConnectError.new("Could not reach #{url}", "unreachable", { "host" => host })
      end
      meta = answer.ok? ? json(answer) : nil
      meta = nil unless meta.is_a?(Hash)
      endpoint = ->(name) { meta[name].is_a?(String) ? meta[name] : "" }
      if meta.nil? || !Js.truthy?(meta["authorization_endpoint"]) || !Js.truthy?(meta["token_endpoint"]) || !Js.truthy?(meta["registration_endpoint"])
        raise ConnectError.new("#{url} did not answer like a Runlight install", "not_runlight", { "url" => url })
      end

      # Its endpoints must be its own, so an address cannot steer this server into requests elsewhere.
      origin = Http::Url.new(url).origin
      %w[authorization_endpoint token_endpoint registration_endpoint].each do |name|
        parsed = Http::Url.parse(endpoint.call(name))
        raise ConnectError.new("#{url} named endpoints on another address", "endpoints", { "url" => url }) if parsed.nil? || parsed.origin != origin
      end
      unless meta["scopes_supported"].is_a?(Array) && meta["scopes_supported"].include?("manage")
        raise ConnectError.new("#{url} runs an older Runlight. Update it, or connect it with an API token from its Settings.", "old", { "url" => url })
      end

      begin
        registered = Safefetch.owner_fetch(meta["registration_endpoint"], {
          "method" => "POST",
          "headers" => { "content-type" => "application/json" },
          "body" => Json.encode({ "client_name" => "Runlight at #{Http::Url.new(back).host}", "redirect_uris" => [back] }),
          "timeoutMs" => 10_000,
        }, runlight.fetcher)
      rescue StandardError
        raise ConnectError.new("Could not reach #{url}", "unreachable", { "host" => host })
      end
      client = json(registered)
      client_id = client.is_a?(Hash) ? client["client_id"] : nil
      if !registered.ok? || !Js.truthy?(client_id)
        # Say why, in the install's own words when it gives them.
        description = client.is_a?(Hash) ? client["error_description"] : nil
        reason = if Js.truthy?(description) then "#{Js.slice(Js.string(description), 0, 200)}."
                 elsif registered.status == 400 then "This server's address must use https."
                 else "It answered #{registered.status}."
                 end
        raise ConnectError.new("#{url} would not let this server connect. #{reason}", "register", { "url" => url, "reason" => reason })
      end
      client_id = Js.string(client_id)
      clear_expired(runlight)

      state = Hashing.random_id(16)
      verifier = Hashing.random_id(32) + Hashing.random_id(32)
      pending = { "url" => url, "client" => client_id, "verifier" => verifier, "redirect" => back, "token" => meta["token_endpoint"],
                  "expires" => runlight.now + PENDING_MS }
      runlight.store.set_setting("connect:#{state}", Json.encode(pending))
      to = Http::Url.new(meta["authorization_endpoint"])
      query = {
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => back,
        "code_challenge" => s256(verifier),
        "code_challenge_method" => "S256",
        "scope" => "manage",
        "state" => state,
      }
      # Which of its sites to offer first, when connecting again for a site already here.
      query["site"] = site unless site == ""
      to.search_params = Http::SearchParams.new(query)
      to.href
    end

    # Finishes connecting when the owner comes back from the consent page. Returns the site's id here.
    def finish_connect(runlight, params)
      state = params.get("state") || ""
      key = "connect:#{state}"
      stored = state.match?(/\A[a-f0-9]{32}\z/) ? runlight.store.setting(key) : nil
      # Each attempt works once.
      runlight.store.set_setting(key, nil) if !stored.nil? && stored != ""
      pending = !stored.nil? && stored != "" ? pending_from(stored, runlight.now) : nil
      if pending.nil?
        raise ConnectError.new("That connection took too long or was already used. Start again.", "expired")
      end
      raise ConnectError.new("The connection was not allowed.", "denied") if params.get("error") == "access_denied"
      raise ConnectError.new((params.get("error_description") || params.get("error")).to_s, "refused") if Js.truthy?(params.get("error"))

      answer = nil
      begin
        answer = Safefetch.owner_fetch(pending["token"], {
          "method" => "POST",
          "headers" => { "content-type" => "application/x-www-form-urlencoded" },
          "body" => Http::SearchParams.new({
            "grant_type" => "authorization_code",
            "code" => params.get("code") || "",
            "client_id" => pending["client"],
            "redirect_uri" => pending["redirect"],
            "code_verifier" => pending["verifier"],
          }).to_s,
          "timeoutMs" => 10_000,
        }, runlight.fetcher)
      rescue StandardError
        answer = nil
      end
      granted = !answer.nil? && answer.ok? ? json(answer) : nil
      token = granted.is_a?(Hash) ? granted["access_token"] : nil
      raise ConnectError.new("#{Http::Url.new(pending["url"]).host} did not give this server a token. Start again.", "token") unless Js.truthy?(token)

      remote = { "url" => pending["url"], "token" => token }
      remote["site"] = granted.key?("site") ? granted["site"] : UNDEFINED
      site = runlight.add_site({ "remote" => remote })
      site["id"]
    end

    private_class_method :pending_from, :clear_expired, :s256, :json
  end
end
