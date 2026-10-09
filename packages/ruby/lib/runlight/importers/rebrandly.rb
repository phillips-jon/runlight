# frozen_string_literal: true

module Runlight
  module Importers
    # Rebrandly. Its API gives only total clicks, with no dates, so links come
    # across with their slugs and domains and start their history fresh.
    #
    # https://developers.rebrandly.com/docs
    class Rebrandly
      include Importer

      BASE = "https://api.rebrandly.com/v1"
      PAGE = 25
      private_constant :BASE, :PAGE

      # now: a callable returning milliseconds.
      def initialize(http = nil, now = nil)
        @http = http || Client.new
        @now = now || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
      end

      def step(credentials, cursor, _known)
        key = Client.trim(credentials["apiKey"].to_s)
        raise ImportError.new("Enter a Rebrandly API key", "import_key", { "service" => "Rebrandly" }) if key.empty?

        headers = { "apikey" => key }
        workspace = Client.trim(credentials["workspace"].to_s)
        headers["workspace"] = workspace unless workspace.empty?
        last = !cursor.nil? && cursor != "" ? "&last=#{Client.encode_uri_component(cursor)}" : ""
        list = @http.get_json("#{BASE}/links?orderBy=createdAt&orderDir=desc&limit=#{PAGE}#{last}", { "headers" => headers })
        links = list.map do |l|
          created = Client.parse_date(l["createdAt"])
          { "link" => {
            "sourceId" => Client.str(l["id"]), "slug" => l["slashtag"], "domain" => Client.coalesce(Client.field(Client.field(l, "domain"), "fullName"), ""),
            "name" => Client.truthy?(l["title"]) ? l["title"] : "", "url" => l["destination"],
            "createdAt" => Client.truthy?(created) ? created : @now.call,
          } }
        end
        finish = list.empty? ? nil : list[-1]
        { "cursor" => list.length == PAGE && Client.truthy?(finish) ? Client.str(finish["id"]) : nil, "total" => nil, "links" => links }
      end
    end
  end
end
