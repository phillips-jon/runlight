# frozen_string_literal: true

module Runlight
  module Importers
    # Bitly. Links are listed per group (every group in the account), with
    # archived ones. Bitly only keeps daily click counts, and only as far back
    # as the account's plan allows. A custom back-half or branded domain wins
    # over the random bit.ly one.
    #
    # https://dev.bitly.com/api-reference
    class Bitly
      include Importer

      BASE = "https://api-ssl.bitly.com/v4"
      PAGE = 20
      private_constant :BASE, :PAGE

      # now: a callable returning milliseconds.
      def initialize(http = nil, now = nil)
        @http = http || Client.new
        @now = now || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
      end

      def step(credentials, cursor, known)
        token = Client.trim(credentials["token"].to_s)
        token = Client.trim(credentials["apiKey"].to_s) if token.empty?
        raise ImportError.new("Enter a Bitly access token", "import_key", { "service" => "Bitly" }) if token.empty?

        headers = { "authorization" => "Bearer #{token}" }
        if !cursor.nil? && cursor != ""
          state = Json.decode(cursor)
        else
          groups = @http.get_json("#{BASE}/groups", { "headers" => headers })["groups"]
          state = { "groups" => groups.map { |g| g["guid"] }, "g" => 0, "after" => nil }
        end
        group = state["groups"][state["g"]]
        return { "cursor" => nil, "total" => nil, "links" => [] } unless Client.truthy?(group)

        after = Client.truthy?(state["after"]) ? "&search_after=#{Client.encode_uri_component(Client.str(state["after"]))}" : ""
        page = @http.get_json("#{BASE}/groups/#{Client.str(group)}/bitlinks?size=#{PAGE}&archived=both#{after}", { "headers" => headers })

        links = []
        page["links"].each do |b|
          next if Client.truthy?(b["is_deleted"])

          short = split(Js.string(Client.coalesce(Client.field(b["custom_bitlinks"], 0), b["id"])))
          if known.call(b["id"], short["slug"], b["long_url"])
            links << { "link" => { "sourceId" => b["id"], "slug" => "", "domain" => "", "name" => "", "url" => b["long_url"], "createdAt" => 0 },
                       "known" => true }
            next
          end
          daily = nil
          begin
            clicks = @http.get_json("#{BASE}/bitlinks/#{Client.encode_uri_component(b["id"])}/clicks?unit=day&units=-1", { "headers" => headers })
            daily = []
            clicks["link_clicks"].each do |c|
              daily << { "day" => c["date"][0, 10], "clicks" => c["clicks"] } if c["clicks"].positive?
            end
          rescue HttpError => e
            # Plans without analytics refuse this; the link still comes across.
            raise e if e.status == 401
          end
          created = Client.parse_date(b["created_at"])
          item = { "link" => {
            "sourceId" => b["id"], "slug" => short["slug"], "domain" => short["domain"], "name" => Client.truthy?(b["title"]) ? b["title"] : "",
            "url" => b["long_url"], "createdAt" => Client.truthy?(created) ? created : @now.call,
          } }
          item["daily"] = daily unless daily.nil?
          links << item
        end

        pagination = page["pagination"]
        search_after = pagination.is_a?(Hash) ? pagination["search_after"] : nil
        following = Client.truthy?(search_after) && page["links"].length == PAGE ? search_after : nil
        more = if !following.nil?
                 state.merge("after" => following)
               elsif state["g"] + 1 < state["groups"].length
                 state.merge("g" => state["g"] + 1, "after" => nil)
               end
        { "cursor" => more.nil? ? nil : Json.encode(more), "total" => nil, "links" => links }
      end

      private

      # A short URL's domain and back-half, from "bit.ly/abc" or "https://t.brand.com/sale".
      def split(value)
        bare = value.sub(%r{\Ahttps?://}, "")
        at = bare.index("/")
        return { "domain" => bare, "slug" => "" } if at.nil?

        { "domain" => bare[0, at], "slug" => bare[(at + 1)..].sub(%r{/\z}, "") }
      end
    end
  end
end
