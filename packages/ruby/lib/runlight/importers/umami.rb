# frozen_string_literal: true

module Runlight
  module Importers
    # Umami v3 (and forks with custom link domains). Signs in with an API key,
    # or with a username and password (stock self-hosted Umami has no API keys).
    # In Umami a link's clicks are events stored under the link's id, with the
    # visitor's session holding place and device.
    class Umami
      include Importer

      PAGE = 5
      private_constant :PAGE

      # now: a callable returning milliseconds.
      def initialize(http = nil, now = nil)
        @http = http || Client.new
        @now = now || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
      end

      # Signs in to an Umami: an API key, or a username and password (stock
      # self-hosted Umami has no API keys). A token from an earlier step is reused.
      # A token the sign-in did not give is UNDEFINED, as TS's `login.token` is then.
      # Returns { "base", "token" }.
      def self.umami_sign_in(http, credentials, token = nil)
        base = Client.trim(credentials["url"].to_s).sub(%r{/+\z}, "")
        unless base.match?(%r{\Ahttps?://[^/]+})
          raise ImportError.new("Enter your Umami address, like https://stats.example.com", "import_umami_address")
        end

        key = Client.trim(credentials["apiKey"].to_s)
        return { "base" => base, "token" => key.empty? ? token : key } if !key.empty? || Client.truthy?(token)

        username = credentials["username"]
        password = credentials["password"]
        if username.nil? || username == "" || password.nil? || password == ""
          raise ImportError.new("Enter an API key, or a username and password", "import_umami_login")
        end

        login = http.get_json("#{base}/api/auth/login", {
          "method" => "POST",
          "headers" => { "content-type" => "application/json" },
          "body" => Json.encode({ "username" => username, "password" => password }),
        })
        { "base" => base, "token" => Client.field(login, "token") }
      end

      def step(credentials, cursor, known)
        # A key comes with every step; only a sign-in token, which expires, rides in the cursor.
        saved = !cursor.nil? && cursor != "" ? Json.decode(cursor) : { "page" => 1 }
        key = Client.trim(credentials["apiKey"].to_s)
        login = Umami.umami_sign_in(@http, credentials, Client.field(saved, "token"))
        base = login["base"]
        state = { "page" => Client.field(saved, "page"), "token" => login["token"] }
        headers = { "authorization" => "Bearer #{Client.str(state["token"])}" }
        list = @http.get_json("#{base}/api/links?page=#{Client.str(state["page"])}&pageSize=#{PAGE}", { "headers" => headers })

        all = lambda do |path|
          out = []
          page = 1
          loop do
            body = @http.get_json("#{base}/api#{path}&page=#{page}&pageSize=1000", { "headers" => headers })
            out.concat(body["data"])
            return out if out.length >= (body["count"].nil? ? Float::INFINITY : body["count"]) || body["data"] == []

            page += 1
          end
        end

        links = []
        list["data"].each do |l|
          next if Client.truthy?(l["deletedAt"])

          if known.call(l["id"], l["slug"], l["url"])
            links << { "link" => { "sourceId" => l["id"], "slug" => l["slug"], "domain" => "", "name" => l["name"], "url" => l["url"], "createdAt" => 0 },
                       "known" => true }
            next
          end
          created = Client.parse_date(l["createdAt"])
          created = Client.truthy?(created) ? created : @now.call
          range = "startAt=#{Client.str(created - 86_400_000)}&endAt=#{Client.str(@now.call + 60_000)}"
          # TS asks for both at once; here one follows the other.
          events = all.call("/websites/#{Js.string(l["id"])}/events?#{range}")
          sessions = all.call("/websites/#{Js.string(l["id"])}/sessions?#{range}")
          info = {}
          sessions.each { |s| info[Client.str(s["id"])] = s }
          clicks = events.map do |e|
            session_id = e["sessionId"]
            s = info.fetch(Client.str(session_id.nil? ? UNDEFINED : session_id), UNDEFINED)
            domain = Client.field(e, "referrerDomain")
            path = Client.field(e, "referrerPath")
            Client.defined({
              "ts" => Client.parse_date(e["createdAt"]),
              "visit" => Client.field(e, "sessionId"),
              "referrer" => Client.truthy?(domain) ? "https://#{Client.str(domain)}#{Client.truthy?(path) ? Client.str(path) : "/"}" : "",
              "path" => Client.field(e, "urlPath"),
              "query" => Client.field(e, "urlQuery"),
              "country" => Client.field(e, "country"),
              "region" => Client.field(s, "region"),
              "city" => Client.field(e, "city"),
              "browser" => Client.field(e, "browser"),
              "os" => Client.field(e, "os"),
              "device" => Client.field(e, "device"),
              "screen" => Client.field(s, "screen"),
              "language" => Client.field(s, "language"),
            })
          end
          links << {
            "link" => { "sourceId" => l["id"], "slug" => l["slug"], "domain" => Client.coalesce(Client.field(Client.field(l, "customDomain"), "domain"), ""),
                        "name" => l["name"], "url" => l["url"], "createdAt" => created },
            "clicks" => clicks,
          }
        end
        more = state["page"] * PAGE < list["count"] && !list["data"].empty?
        following = key.empty? ? { "page" => state["page"] + 1, "token" => state["token"] } : { "page" => state["page"] + 1 }
        { "cursor" => more ? Json.encode(following) : nil, "total" => list["count"], "links" => links }
      end
    end
  end
end
