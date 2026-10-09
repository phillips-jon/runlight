# frozen_string_literal: true

module Runlight
  # The MCP server at {base}/mcp: Streamable HTTP without sessions or a stream,
  # JSON-RPC in and JSON out. Every tool is a read of the HTTP API, made with
  # the caller's own credentials, so the MCP server can see exactly what the
  # token can and nothing more.
  #
  # Reading the API is the caller's: `read_api` is a callable(path, params) returning an Http::Response, params
  # being a list of [name, value] pairs, that reads one API path with the caller's credentials, as ApiRead does in
  # TypeScript.
  module Mcp
    # Newest first; a client asking for one we do not know is answered with the newest.
    PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].freeze

    INSTRUCTIONS = <<~'TEXT'.chomp
      Runlight is privacy friendly web analytics. These tools read one install's numbers: visitors, visits, pageviews, bounce rate, visit duration, where visitors came from, what they read, goals and revenue, AI assistants that sent visitors or fetched pages, and short links.

      Start with list_sites when you do not know the site id; every other tool defaults to the first site. Dates are in the site's own timezone, which each answer includes. Periods: today, yesterday, 7d, 30d, 90d, month (this month so far), last_month, year (this year so far), 12mo, all; or from and to as YYYY-MM-DD. Answers compare with the period before unless compare is off.

      Filters narrow any report to matching visits, written dimension:op:value with op one of is, not, contains, for example "channel:is:Organic Search" or "page:contains:/blog". Visitors are counted per day without cookies, so a visitor seen on two days counts twice across a long range.
    TEXT

    # The dimensions a breakdown reads, as query.ts's DIMENSIONS lists them.
    DIMENSIONS = %w[
      page hostname event entry exit referrer source channel utm_source utm_medium utm_campaign utm_term
      utm_content country region city browser browser_version os os_version device screen language ai_agent ai_page
    ].freeze
    # query.ts's MAX_FILTERS.
    MAX_FILTERS = 6

    RANGE_KEYS = %w[site period from to filters].freeze
    COMPARE_KEYS = [*RANGE_KEYS, "compare", "compare_from", "compare_to"].freeze
    private_constant :DIMENSIONS, :MAX_FILTERS, :RANGE_KEYS, :COMPARE_KEYS

    @tools = nil

    module_function

    def range
      {
        "site" => { "type" => "string", "description" => "Site id from list_sites. Defaults to the first site." },
        "period" => {
          "type" => "string",
          "enum" => %w[today yesterday 7d 30d 90d month last_month year 12mo all],
          "description" => "The date range. Defaults to 30d. Ignored when from and to are given.",
        },
        "from" => { "type" => "string", "description" => "First day, YYYY-MM-DD, with to." },
        "to" => { "type" => "string", "description" => "Last day, YYYY-MM-DD, inclusive." },
        "filters" => {
          "type" => "array",
          "items" => { "type" => "string" },
          "maxItems" => MAX_FILTERS,
          "description" => "Narrow to matching visits, up to #{MAX_FILTERS} at once, each \"dimension:op:value\" with op is, not, or contains.",
        },
      }
    end

    def compare
      {
        "compare" => { "type" => "string", "enum" => %w[previous year custom off],
                       "description" => "What to compare with. Defaults to previous, the same length of time just before." },
        "compare_from" => { "type" => "string", "description" => "For compare custom: first day, YYYY-MM-DD." },
        "compare_to" => { "type" => "string", "description" => "For compare custom: last day, YYYY-MM-DD." },
      }
    end

    def range_params(args, keys)
      params = []
      keys.each do |key|
        value = Js.get(args, key)
        if key == "filters"
          value.each { |f| params << ["filter", Js.string(f)] } if value.is_a?(Array)
        elsif !value.equal?(UNDEFINED) && !value.nil? && value != ""
          params << [key, Js.string(value)]
        end
      end
      params
    end

    def read(path, keys, extra = nil)
      ->(args) { { "path" => path, "params" => range_params(args, keys) + (extra ? extra.call(args) : []) } }
    end

    # Math.min(top, Math.max(1, Number(value) || fallback)) as text.
    def limit(value, fallback)
      n = value.equal?(UNDEFINED) ? Float::NAN : Js.number(value)
      n = fallback unless Js.truthy?(n)
      Js.string([100, [1, n].max].min)
    end

    # The tools, each with "name", "title", "description", "inputSchema", "request" (args to an API path and
    # query), and "shape" (trims an answer before it goes back, when the API's carries more than an assistant
    # needs) or nil.
    def tools
      return @tools unless @tools.nil?

      range = self.range
      compare = self.compare
      @tools = [
        {
          "name" => "list_sites",
          "title" => "List sites",
          "description" => "Every site this token can read, with its id, name, hostnames, timezone, and when it last had a visit.",
          "inputSchema" => { "type" => "object", "properties" => {} },
          "request" => ->(_args) { { "path" => "/api/sites", "params" => [] } },
          "shape" => nil,
        },
        {
          "name" => "get_stats",
          "title" => "Headline numbers",
          "description" => "Visitors, visits, pageviews, views per visit, bounce rate (0 to 1), and visit duration (milliseconds) for a range, with the comparison range's numbers as previous.",
          "inputSchema" => { "type" => "object", "properties" => range.merge(compare) },
          "request" => read("/api/stats", COMPARE_KEYS),
          "shape" => nil,
        },
        {
          "name" => "get_timeseries",
          "title" => "Numbers over time",
          "description" => "The headline numbers for each hour, day, week, or month of a range, with the comparison range's points lined up by position.",
          "inputSchema" => {
            "type" => "object",
            "properties" => range.merge(compare).merge(
              "interval" => { "type" => "string", "enum" => %w[hour day week month], "description" => "Chosen from the range when left out." },
            ),
          },
          "request" => read("/api/series", [*COMPARE_KEYS, "interval"]),
          "shape" => nil,
        },
        {
          "name" => "get_breakdown",
          "title" => "Top values of a dimension",
          "description" => "Rows for one dimension, most visitors first: pages, entry and exit pages, referrers, sources, channels (Direct, Organic Search, Social, AI, and so on), UTM tags, countries, regions, cities, browsers, operating systems, devices, screens, languages, custom events, and AI agents that fetched pages (ai_agent, ai_page).",
          "inputSchema" => {
            "type" => "object",
            "properties" => range.merge(
              "dimension" => { "type" => "string", "enum" => DIMENSIONS },
              "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 100, "description" => "Rows to return. Defaults to 10." },
              "page" => { "type" => "integer", "minimum" => 1, "description" => "For more rows: 2 is the next limit rows." },
            ),
            "required" => ["dimension"],
          },
          "request" => read("/api/breakdown", [*RANGE_KEYS, "dimension", "page"], ->(args) { [["limit", limit(Js.get(args, "limit"), 10)]] }),
          "shape" => nil,
        },
        {
          "name" => "list_funnels",
          "title" => "Funnels",
          "description" => "Every funnel with how many visits reached each step in order within the same visit. Divide a step by the one before it for that step's conversion rate.",
          "inputSchema" => { "type" => "object", "properties" => range.dup },
          "request" => read("/api/funnels", RANGE_KEYS),
          "shape" => nil,
        },
        {
          "name" => "get_event_properties",
          "title" => "An event's properties",
          "description" => "The properties sent with one custom event and the values each took, most common first. Automatic events have their own: \"Outbound link\" and \"File download\" carry url, and \"404\" carries path. Leave key out to see every property name and the values of the most used one.",
          "inputSchema" => {
            "type" => "object",
            "properties" => range.merge(
              "event" => { "type" => "string", "description" => "The event's name, as get_breakdown with dimension event lists it." },
              "key" => { "type" => "string", "description" => "Which property. Defaults to the most used one." },
              "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 100, "description" => "Values to return. Defaults to 25." },
            ),
            "required" => ["event"],
          },
          "request" => read("/api/event-props", [*RANGE_KEYS, "event", "key"], ->(args) { [["limit", limit(Js.get(args, "limit"), 25)]] }),
          "shape" => nil,
        },
        {
          "name" => "get_visit_times",
          "title" => "When people visit",
          "description" => "Visits by weekday and hour in the site's timezone: grid[weekday][hour], Monday first, hours 0 to 23.",
          "inputSchema" => { "type" => "object", "properties" => range.dup },
          "request" => read("/api/rhythm", RANGE_KEYS),
          "shape" => lambda { |body|
            {
              "site" => Js.get(body, "site"),
              "range" => Js.get(body, "range"),
              "weekdays" => %w[Mon Tue Wed Thu Fri Sat Sun],
              "grid" => Js.get(body, "grid"),
            }
          },
        },
        {
          "name" => "get_realtime",
          "title" => "Right now",
          "description" => "People on the site in the last five minutes, the pages they are reading, where they came from, their countries, and the latest activity.",
          "inputSchema" => { "type" => "object", "properties" => { "site" => range["site"] } },
          "request" => read("/api/realtime", ["site"]),
          "shape" => nil,
        },
        {
          "name" => "list_goals",
          "title" => "Goals and conversions",
          "description" => "Every goal with its conversions, converted visitors, conversion rate (0 to 1), and revenue for a range, with the comparison range's numbers as previous.",
          "inputSchema" => { "type" => "object", "properties" => range.merge(compare) },
          "request" => read("/api/goals", COMPARE_KEYS),
          "shape" => nil,
        },
        {
          "name" => "get_goal",
          "title" => "One goal in detail",
          "description" => "One goal's conversions over time and by channel, source, and page. Find the goal_id with list_goals.",
          "inputSchema" => { "type" => "object", "properties" => range.merge("goal_id" => { "type" => "string" }), "required" => ["goal_id"] },
          "request" => lambda { |args|
            id = Js.get(args, "goal_id")
            {
              "path" => "/api/goals/#{Js.encode_uri_component(Js.string(id.nil? || id.equal?(UNDEFINED) ? "" : id))}",
              "params" => range_params(args, RANGE_KEYS),
            }
          },
          "shape" => nil,
        },
        {
          "name" => "get_journeys",
          "title" => "Paths through the site",
          "description" => "The paths visits take, page by page: the top pages at each step, how many went no further, the flows between steps, and the commonest whole paths. A refresh counts once. start and end follow only paths from or to a page.",
          "inputSchema" => {
            "type" => "object",
            "properties" => range.merge(
              "steps" => { "type" => "integer", "minimum" => 2, "maximum" => 8, "description" => "How many pages of each path. Defaults to 5." },
              "start" => { "type" => "string", "description" => "Only paths from this page, such as /pricing." },
              "end" => { "type" => "string", "description" => "Only paths that reach this page, cut there." },
            ),
          },
          "request" => read("/api/journeys", [*RANGE_KEYS, "steps", "start", "end"]),
          "shape" => nil,
        },
        {
          "name" => "list_links",
          "title" => "Short links",
          "description" => "Every short link with its destination and its clicks in the range.",
          "inputSchema" => { "type" => "object", "properties" => { "site" => range["site"], "period" => range["period"], "from" => range["from"], "to" => range["to"] } },
          "request" => read("/api/links", %w[site period from to]),
          "shape" => nil,
        },
      ]
    end

    def rpc_error(id, code, message)
      { "jsonrpc" => "2.0", "id" => id.equal?(UNDEFINED) ? nil : id, "error" => { "code" => code, "message" => message } }
    end

    # Runs one tool by name, as the MCP server does; the dashboard's assistant calls it too. `params` holds name and
    # arguments. Returns { "content" => [{ "type", "text" }], "isError"? }. Raises McpError for an unknown tool.
    def call_tool(params, read_api)
      name = Js.get(params, "name")
      tool = tools.find { |one| one["name"] == name }
      raise McpError.new("Unknown tool \"#{Js.string(name)}\"", -32_602) if tool.nil?

      given = Js.get(params, "arguments")
      args = Js.truthy?(given) && Js.object?(given) ? given : {}
      request = tool["request"].call(args)
      answer = read_api.call(request["path"], request["params"])
      parsed, body = Js.parse_json(answer.text)
      body = {} unless parsed
      unless answer.ok?
        error = Js.get(body, "error")
        text = Js.string(error.nil? || error.equal?(UNDEFINED) ? "Runlight answered #{answer.status}" : error)
        return { "content" => [{ "type" => "text", "text" => text }], "isError" => true }
      end
      { "content" => [{ "type" => "text", "text" => Json.encode(tool["shape"] ? tool["shape"].call(body) : body) }] }
    end

    # The answer, or nil for a notification.
    def answer(message, read_api)
      id = Js.get(message, "id")
      notification = id.equal?(UNDEFINED)
      method = Js.get(message, "method")
      return notification ? nil : rpc_error(id, -32_600, "Invalid request") if Js.get(message, "jsonrpc") != "2.0" || !method.is_a?(String)

      given = Js.get(message, "params")
      params = Js.truthy?(given) && Js.object?(given) ? given : {}
      begin
        case method
        when "initialize"
          asked = Js.get(params, "protocolVersion")
          asked = Js.string(asked.nil? || asked.equal?(UNDEFINED) ? "" : asked)
          result = {
            "protocolVersion" => PROTOCOL_VERSIONS.include?(asked) ? asked : PROTOCOL_VERSIONS[0],
            "capabilities" => { "tools" => { "listChanged" => false } },
            "serverInfo" => { "name" => "runlight", "title" => "Runlight", "version" => Version.version },
            "instructions" => INSTRUCTIONS,
          }
        when "ping"
          result = {}
        when "tools/list"
          result = {
            "tools" => tools.map do |t|
              {
                "name" => t["name"],
                "title" => t["title"],
                "description" => t["description"],
                "inputSchema" => t["inputSchema"],
                "annotations" => { "readOnlyHint" => true, "openWorldHint" => false },
              }
            end,
          }
        when "tools/call"
          result = call_tool(params, read_api)
        else
          return notification ? nil : rpc_error(id, -32_601, "Unknown method \"#{method}\"")
        end
        notification ? nil : { "jsonrpc" => "2.0", "id" => id, "result" => result }
      rescue StandardError => e
        return nil if notification

        e.is_a?(McpError) ? rpc_error(id, e.code, e.message) : rpc_error(id, -32_603, "Internal error")
      end
    end

    # Answers one POST to the MCP endpoint, already authorised.
    def mcp_response(request, read_api)
      headers = { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }
      parsed, body = Js.parse_json(request.text)
      return Http::Response.new(Json.encode(rpc_error(nil, -32_700, "Send a JSON-RPC message")), status: 400, headers: headers) if !parsed || !Js.object?(body)

      # Batches were in the 2025-03-26 protocol; answering them costs nothing.
      if body.is_a?(Array)
        answers = body.map { |message| answer(message, read_api) }.compact
        return answers.empty? ? Http::Response.new("", status: 202) : Http::Response.new(Json.encode(answers), status: 200, headers: headers)
      end
      one = answer(body, read_api)
      one.nil? ? Http::Response.new("", status: 202) : Http::Response.new(Json.encode(one), status: 200, headers: headers)
    end

    private_class_method :range, :compare, :range_params, :read, :limit, :rpc_error, :answer
  end
end
