# frozen_string_literal: true

module Runlight
  module Importers
    # Short.io. Links are listed per domain. Daily click counts come from the
    # statistics API, paced to its limit of 60 requests a minute, so a step
    # holds only a few links.
    #
    # https://developers.short.io/reference
    class Shortio
      include Importer

      API = "https://api.short.io"
      STATS = "https://statistics.short.io/statistics"
      PAGE = 8
      # The statistics API allows 60 requests a minute.
      STATS_GAP_MS = 1050
      private_constant :API, :STATS, :PAGE, :STATS_GAP_MS

      # now: a callable returning milliseconds.
      def initialize(http = nil, now = nil)
        @http = http || Client.new
        @now = now || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
      end

      def step(credentials, cursor, known)
        key = Client.trim(credentials["apiKey"].to_s)
        raise ImportError.new("Enter a Short.io secret API key", "import_key", { "service" => "Short.io" }) if key.empty?

        headers = { "authorization" => key }
        if !cursor.nil? && cursor != ""
          state = Json.decode(cursor)
        else
          domains = @http.get_json("#{API}/api/domains?limit=300", { "headers" => headers })
          state = {
            "domains" => domains.map { |d| { "id" => d["id"], "hostname" => d["hostname"] } },
            "d" => 0,
            "token" => nil,
            "total" => nil,
          }
        end
        domain = state["domains"][state["d"]]
        return { "cursor" => nil, "total" => nil, "links" => [] } unless Client.truthy?(domain)

        token = Client.truthy?(state["token"]) ? "&pageToken=#{Client.encode_uri_component(Client.str(state["token"]))}" : ""
        page = @http.get_json("#{API}/api/links?domain_id=#{Client.str(domain["id"])}&limit=#{PAGE}#{token}", { "headers" => headers })

        links = []
        page["links"].each do |l|
          id = Client.str(Client.coalesce(Client.field(l, "idString"), l["id"]))
          if known.call(id, l["path"], l["originalURL"])
            links << { "link" => { "sourceId" => id, "slug" => l["path"], "domain" => "", "name" => "", "url" => l["originalURL"], "createdAt" => 0 },
                       "known" => true }
            next
          end
          daily = nil
          begin
            @http.pause(STATS_GAP_MS)
            body = @http.get_json("#{STATS}/link/#{Client.encode_uri_component(id)}/by_interval", {
              "method" => "POST",
              "headers" => headers.merge("content-type" => "application/json"),
              "body" => Json.encode({ "period" => "total", "clicksChartInterval" => "day", "tz" => "UTC" }),
            })
            raw = body.is_a?(Hash) ? body["clickStatistics"] : nil
            points = if raw.is_a?(Array) then raw
                     elsif raw.is_a?(Hash) then dataset(raw) || []
                     else []
                     end
            daily = []
            points.each do |p|
              y = p.is_a?(Hash) ? p["y"] : nil
              next unless positive?(y)

              x = p["x"]
              ms = x.is_a?(Integer) || x.is_a?(Float) ? x : Client.parse_date(x)
              # A point whose date cannot be read is left out, not the link.
              day = begin
                Client.iso_string(ms)[0, 10]
              rescue RangeError
                next
              end
              daily << { "day" => day, "clicks" => y }
            end
          rescue HttpError => e
            raise e if e.status == 401
          end
          created = Client.parse_date(l["createdAt"])
          item = { "link" => {
            "sourceId" => id, "slug" => l["path"], "domain" => domain["hostname"], "name" => Client.truthy?(l["title"]) ? l["title"] : "",
            "url" => l["originalURL"], "createdAt" => Client.truthy?(created) ? created : @now.call,
          } }
          item["daily"] = daily unless daily.nil?
          links << item
        end

        following = page["nextPageToken"]
        more = if Client.truthy?(following)
                 state.merge("token" => following)
               elsif state["d"] + 1 < state["domains"].length
                 state.merge("d" => state["d"] + 1, "token" => nil)
               end
        { "cursor" => more.nil? ? nil : Json.encode(more), "total" => nil, "links" => links }
      end

      private

      # clickStatistics.datasets[0].data, or nil where any of it is missing.
      def dataset(raw)
        sets = raw["datasets"]
        first = sets.is_a?(Array) ? sets[0] : nil
        first.is_a?(Hash) ? first["data"] : nil
      end

      # `y > 0` as JavaScript compares it.
      def positive?(y)
        return y.positive? if y.is_a?(Integer) || y.is_a?(Float)
        return Client.number(y).positive? if y.is_a?(String)

        y == true
      end
    end
  end
end
