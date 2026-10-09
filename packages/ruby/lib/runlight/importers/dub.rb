# frozen_string_literal: true

module Runlight
  module Importers
    # Dub. Links come from GET /links (cursor pages of up to 100, archived
    # included). Click history is per click from /events where the plan allows,
    # else daily counts from /analytics, else none; the first link decides.
    # What the account's plan lets us read rides in the cursor as `history`:
    # "events" (Business), "daily" (Pro), "none" (Free), or nil before the first link.
    #
    # https://dub.co/docs/api-reference
    class Dub
      include Importer

      BASE = "https://api.dub.co"
      PAGE = 10
      private_constant :BASE, :PAGE

      # Whether Dub said the plan does not include what was asked (403, or 402).
      # Any other failure (a server error that outlasts the retries, say) fails
      # the step and leaves the history mode as it was.
      def self.plan_refused?(error)
        [403, 402].include?(error.status)
      end

      # now: a callable returning milliseconds.
      def initialize(http = nil, now = nil)
        @http = http || Client.new
        @now = now || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
      end

      def step(credentials, cursor, known)
        key = Client.trim(credentials["apiKey"].to_s)
        raise ImportError.new("Enter a Dub API key", "import_key", { "service" => "Dub" }) if key.empty?

        headers = { "authorization" => "Bearer #{key}" }
        state = !cursor.nil? && cursor != "" ? Json.decode(cursor) : { "after" => nil, "history" => nil }
        history = Client.field(state, "history")
        after = Client.truthy?(state["after"]) ? "&startingAfter=#{Client.encode_uri_component(Client.str(state["after"]))}" : ""
        list = @http.get_json("#{BASE}/links?pageSize=#{PAGE}&showArchived=true#{after}", { "headers" => headers })

        links = []
        list.each do |l|
          if known.call(l["id"], l["key"], l["url"])
            links << { "link" => { "sourceId" => l["id"], "slug" => l["key"], "domain" => "", "name" => "", "url" => l["url"], "createdAt" => 0 },
                       "known" => true }
            next
          end
          clicks = nil
          daily = nil
          if history.nil? || history == "events"
            begin
              clicks = []
              page = 1
              loop do
                events = @http.get_json(
                  "#{BASE}/events?event=clicks&linkId=#{Client.encode_uri_component(l["id"])}&interval=all&sortOrder=asc&limit=1000&page=#{page}",
                  { "headers" => headers },
                )
                events.each do |e|
                  click = Client.field(e, "click")
                  referer = Client.field(click, "referer")
                  referer_url = Client.field(click, "refererUrl")
                  device = Client.field(click, "device")
                  referrer = if Client.truthy?(referer_url) then referer_url
                             elsif Client.truthy?(referer) && referer != "(direct)" then "https://#{Client.str(referer)}/"
                             else ""
                             end
                  clicks << Client.defined({
                    "ts" => Client.parse_date(e.is_a?(Hash) ? e["timestamp"] : nil),
                    "visit" => Client.field(click, "id"),
                    "referrer" => referrer,
                    "country" => Client.field(click, "country"),
                    "region" => Client.field(click, "region"),
                    "city" => Client.field(click, "city"),
                    "device" => device.is_a?(String) ? Js.lower(device) : UNDEFINED,
                    "browser" => Client.field(click, "browser"),
                    "os" => Client.field(click, "os"),
                  })
                end
                break if events.length < 1000

                page += 1
              end
              history = "events"
            rescue HttpError => e
              raise e unless Dub.plan_refused?(e)

              clicks = nil
              history = "daily"
            end
          end
          if history == "daily"
            begin
              series = @http.get_json(
                "#{BASE}/analytics?event=clicks&groupBy=timeseries&interval=all&linkId=#{Client.encode_uri_component(l["id"])}",
                { "headers" => headers },
              )
              daily = []
              series.each do |p|
                daily << { "day" => p["start"][0, 10], "clicks" => p["clicks"] } if p["clicks"].positive?
              end
            rescue HttpError => e
              raise e unless Dub.plan_refused?(e)

              history = "none"
            end
          end
          created = Client.parse_date(l["createdAt"])
          item = { "link" => {
            "sourceId" => l["id"], "slug" => l["key"], "domain" => l["domain"], "name" => Client.truthy?(l["title"]) ? l["title"] : "",
            "url" => l["url"], "createdAt" => Client.truthy?(created) ? created : @now.call,
          } }
          item["clicks"] = clicks unless clicks.nil?
          item["daily"] = daily unless daily.nil?
          links << item
        end
        last = list.empty? ? nil : list[-1]
        {
          "cursor" => list.length == PAGE && Client.truthy?(last) ? Json.encode({ "after" => last["id"], "history" => history }) : nil,
          "total" => nil,
          "links" => links,
        }
      end
    end
  end
end
