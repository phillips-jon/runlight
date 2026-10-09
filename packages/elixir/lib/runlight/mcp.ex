defmodule Runlight.Mcp do
  @moduledoc false
  # Internal. The MCP server at {base}/mcp: Streamable HTTP without sessions
  # or a stream, JSON-RPC in and JSON out (the SDK's mcp.ts). Every tool is a
  # read of the HTTP API, made with the caller's own credentials, so the MCP
  # server can see exactly what the token can and nothing more.

  alias Runlight.Assets
  alias Runlight.Http.Request
  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Query

  # Newest first; a client asking for one we do not know is answered with the newest.
  @protocol_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

  @instructions """
  Runlight is privacy friendly web analytics. These tools read one install's numbers: visitors, visits, pageviews, bounce rate, visit duration, where visitors came from, what they read, goals and revenue, AI assistants that sent visitors or fetched pages, and short links.

  Start with list_sites when you do not know the site id; every other tool defaults to the first site. Dates are in the site's own timezone, which each answer includes. Periods: today, yesterday, 7d, 30d, 90d, month (this month so far), last_month, year (this year so far), 12mo, all; or from and to as YYYY-MM-DD. Answers compare with the period before unless compare is off.

  Filters narrow any report to matching visits, written dimension:op:value with op one of is, not, contains, for example "channel:is:Organic Search" or "page:contains:/blog". Visitors are counted per day without cookies, so a visitor seen on two days counts twice across a long range.\
  """

  @doc "What the server tells a client about itself and its tools."
  def instructions, do: @instructions

  defp range do
    max = Query.max_filters()

    [
      site: JS.obj(type: "string", description: "Site id from list_sites. Defaults to the first site."),
      period:
        JS.obj(
          type: "string",
          enum: ["today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"],
          description: "The date range. Defaults to 30d. Ignored when from and to are given."
        ),
      from: JS.obj(type: "string", description: "First day, YYYY-MM-DD, with to."),
      to: JS.obj(type: "string", description: "Last day, YYYY-MM-DD, inclusive."),
      filters:
        JS.obj(
          type: "array",
          items: JS.obj(type: "string"),
          maxItems: max,
          description: ~s(Narrow to matching visits, up to #{max} at once, each "dimension:op:value" with op is, not, or contains.)
        )
    ]
  end

  defp compare do
    [
      compare:
        JS.obj(
          type: "string",
          enum: ["previous", "year", "custom", "off"],
          description: "What to compare with. Defaults to previous, the same length of time just before."
        ),
      compare_from: JS.obj(type: "string", description: "For compare custom: first day, YYYY-MM-DD."),
      compare_to: JS.obj(type: "string", description: "For compare custom: last day, YYYY-MM-DD.")
    ]
  end

  @range_keys ~w(site period from to filters)
  @compare_keys @range_keys ++ ~w(compare compare_from compare_to)

  defp range_params(args, keys) do
    Enum.flat_map(keys, fn key ->
      value = JS.prop(args, key)

      cond do
        key == "filters" -> if is_list(value), do: Enum.map(value, &{"filter", JS.string(&1)}), else: []
        value in [:undefined, nil, ""] -> []
        true -> [{key, JS.string(value)}]
      end
    end)
  end

  defp read(path, keys, extra \\ fn _ -> [] end), do: fn args -> {path, range_params(args, keys) ++ extra.(args)} end

  defp limit(args, fallback) do
    n = JS.number(JS.prop(args, "limit"))
    n = if JS.truthy?(n), do: n, else: fallback
    n = case n, do: (:infinity -> 100; :neg_infinity -> 1; n -> n)
    JS.string(n |> max(1) |> min(100))
  end

  @doc "Every tool, each `%{name, title, description, input_schema, request, shape}`."
  def tools do
    r = range()
    c = compare()

    [
      %{
        name: "list_sites",
        title: "List sites",
        description: "Every site this token can read, with its id, name, hostnames, timezone, and when it last had a visit.",
        input_schema: JS.obj(type: "object", properties: JS.obj([])),
        request: fn _ -> {"/api/sites", []} end
      },
      %{
        name: "get_stats",
        title: "Headline numbers",
        description:
          "Visitors, visits, pageviews, views per visit, bounce rate (0 to 1), and visit duration (milliseconds) for a range, with the comparison range's numbers as previous.",
        input_schema: JS.obj(type: "object", properties: JS.obj(r ++ c)),
        request: read("/api/stats", @compare_keys)
      },
      %{
        name: "get_timeseries",
        title: "Numbers over time",
        description:
          "The headline numbers for each hour, day, week, or month of a range, with the comparison range's points lined up by position.",
        input_schema:
          JS.obj(
            type: "object",
            properties:
              JS.obj(
                r ++
                  c ++
                  [interval: JS.obj(type: "string", enum: ["hour", "day", "week", "month"], description: "Chosen from the range when left out.")]
              )
          ),
        request: read("/api/series", @compare_keys ++ ["interval"])
      },
      %{
        name: "get_breakdown",
        title: "Top values of a dimension",
        description:
          "Rows for one dimension, most visitors first: pages, entry and exit pages, referrers, sources, channels (Direct, Organic Search, Social, AI, and so on), UTM tags, countries, regions, cities, browsers, operating systems, devices, screens, languages, custom events, and AI agents that fetched pages (ai_agent, ai_page).",
        input_schema:
          JS.obj(
            type: "object",
            properties:
              JS.obj(
                r ++
                  [
                    dimension: JS.obj(type: "string", enum: Query.dimensions()),
                    limit: JS.obj(type: "integer", minimum: 1, maximum: 100, description: "Rows to return. Defaults to 10."),
                    page: JS.obj(type: "integer", minimum: 1, description: "For more rows: 2 is the next limit rows.")
                  ]
              ),
            required: ["dimension"]
          ),
        request: read("/api/breakdown", @range_keys ++ ["dimension", "page"], fn args -> [{"limit", limit(args, 10)}] end)
      },
      %{
        name: "list_funnels",
        title: "Funnels",
        description:
          "Every funnel with how many visits reached each step in order within the same visit. Divide a step by the one before it for that step's conversion rate.",
        input_schema: JS.obj(type: "object", properties: JS.obj(r)),
        request: read("/api/funnels", @range_keys)
      },
      %{
        name: "get_event_properties",
        title: "An event's properties",
        description:
          ~s(The properties sent with one custom event and the values each took, most common first. Automatic events have their own: "Outbound link" and "File download" carry url, and "404" carries path. Leave key out to see every property name and the values of the most used one.),
        input_schema:
          JS.obj(
            type: "object",
            properties:
              JS.obj(
                r ++
                  [
                    event: JS.obj(type: "string", description: "The event's name, as get_breakdown with dimension event lists it."),
                    key: JS.obj(type: "string", description: "Which property. Defaults to the most used one."),
                    limit: JS.obj(type: "integer", minimum: 1, maximum: 100, description: "Values to return. Defaults to 25.")
                  ]
              ),
            required: ["event"]
          ),
        request: read("/api/event-props", @range_keys ++ ["event", "key"], fn args -> [{"limit", limit(args, 25)}] end)
      },
      %{
        name: "get_visit_times",
        title: "When people visit",
        description: "Visits by weekday and hour in the site's timezone: grid[weekday][hour], Monday first, hours 0 to 23.",
        input_schema: JS.obj(type: "object", properties: JS.obj(r)),
        request: read("/api/rhythm", @range_keys),
        shape: fn body ->
          JS.obj(site: JS.prop(body, "site"), range: JS.prop(body, "range"), weekdays: ~w(Mon Tue Wed Thu Fri Sat Sun), grid: JS.prop(body, "grid"))
        end
      },
      %{
        name: "get_realtime",
        title: "Right now",
        description: "People on the site in the last five minutes, the pages they are reading, where they came from, their countries, and the latest activity.",
        input_schema: JS.obj(type: "object", properties: JS.obj(site: r[:site])),
        request: read("/api/realtime", ["site"])
      },
      %{
        name: "list_goals",
        title: "Goals and conversions",
        description:
          "Every goal with its conversions, converted visitors, conversion rate (0 to 1), and revenue for a range, with the comparison range's numbers as previous.",
        input_schema: JS.obj(type: "object", properties: JS.obj(r ++ c)),
        request: read("/api/goals", @compare_keys)
      },
      %{
        name: "get_goal",
        title: "One goal in detail",
        description: "One goal's conversions over time and by channel, source, and page. Find the goal_id with list_goals.",
        input_schema: JS.obj(type: "object", properties: JS.obj(r ++ [goal_id: JS.obj(type: "string")]), required: ["goal_id"]),
        request: fn args ->
          {"/api/goals/#{JS.encode_uri_component(args |> JS.prop("goal_id") |> JS.nullish("") |> JS.string())}", range_params(args, @range_keys)}
        end
      },
      %{
        name: "get_journeys",
        title: "Paths through the site",
        description:
          "The paths visits take, page by page: the top pages at each step, how many went no further, the flows between steps, and the commonest whole paths. A refresh counts once. start and end follow only paths from or to a page.",
        input_schema:
          JS.obj(
            type: "object",
            properties:
              JS.obj(
                r ++
                  [
                    steps: JS.obj(type: "integer", minimum: 2, maximum: 8, description: "How many pages of each path. Defaults to 5."),
                    start: JS.obj(type: "string", description: "Only paths from this page, such as /pricing."),
                    end: JS.obj(type: "string", description: "Only paths that reach this page, cut there.")
                  ]
              )
          ),
        request: read("/api/journeys", @range_keys ++ ["steps", "start", "end"])
      },
      %{
        name: "list_links",
        title: "Short links",
        description: "Every short link with its destination and its clicks in the range.",
        input_schema: JS.obj(type: "object", properties: JS.obj(site: r[:site], period: r[:period], from: r[:from], to: r[:to])),
        request: read("/api/links", ["site", "period", "from", "to"])
      }
    ]
  end

  defp rpc_error(id, code, message), do: JS.obj(jsonrpc: "2.0", id: id, error: JS.obj(code: code, message: message))

  @doc "Runs one tool by name, as the MCP server does; the dashboard's assistant calls it too."
  def call_tool(params, read_api) do
    name = JS.prop(params, "name")

    case Enum.find(tools(), &(&1.name == name)) do
      nil ->
        throw({:rpc, -32602, ~s(Unknown tool "#{JS.string(name)}")})

      tool ->
        args = case JS.prop(params, "arguments"), do: (a when is_list(a) -> Object.new(); %Object{} = a -> a; _ -> Object.new())
        {path, query} = tool.request.(args)
        answer = read_api.(path, query)
        body = case Response.json(answer), do: ({:ok, b} -> b; :error -> Object.new())

        if Response.ok?(answer) do
          text = JS.stringify(if tool[:shape], do: tool.shape.(body), else: body)
          JS.obj(content: [JS.obj(type: "text", text: text)])
        else
          error = JS.prop(body, "error")
          text = if error in [:undefined, nil], do: "Runlight answered #{answer.status}", else: JS.string(error)
          JS.obj(content: [JS.obj(type: "text", text: text)], isError: true)
        end
    end
  end

  defp answer(message, read_api) do
    id = JS.prop(message, "id")
    notification = id == :undefined
    id = if notification, do: nil, else: id
    method = JS.prop(message, "method")

    if JS.prop(message, "jsonrpc") != "2.0" or not is_binary(method) do
      if notification, do: nil, else: rpc_error(id, -32600, "Invalid request")
    else
      params = case JS.prop(message, "params"), do: (p when is_list(p) -> p; %Object{} = p -> p; _ -> Object.new())

      try do
        result =
          case method do
            "initialize" ->
              asked = params |> JS.prop("protocolVersion") |> JS.nullish("") |> JS.string()

              JS.obj(
                protocolVersion: if(asked in @protocol_versions, do: asked, else: hd(@protocol_versions)),
                capabilities: JS.obj(tools: JS.obj(listChanged: false)),
                serverInfo: JS.obj(name: "runlight", title: "Runlight", version: Assets.version()),
                instructions: @instructions
              )

            "ping" ->
              Object.new()

            "tools/list" ->
              JS.obj(
                tools:
                  Enum.map(tools(), fn t ->
                    JS.obj(
                      name: t.name,
                      title: t.title,
                      description: t.description,
                      inputSchema: t.input_schema,
                      annotations: JS.obj(readOnlyHint: true, openWorldHint: false)
                    )
                  end)
              )

            "tools/call" ->
              call_tool(params, read_api)

            _ ->
              throw({:unknown, ~s(Unknown method "#{method}")})
          end

        if notification, do: nil, else: JS.obj(jsonrpc: "2.0", id: id, result: result)
      rescue
        _ -> if notification, do: nil, else: rpc_error(id, -32603, "Internal error")
      catch
        {:unknown, text} -> if notification, do: nil, else: rpc_error(id, -32601, text)
        {:rpc, code, text} -> if notification, do: nil, else: rpc_error(id, code, text)
      end
    end
  end

  @doc "Answers one POST to the MCP endpoint, already authorised."
  def response(%Request{} = request, read_api) do
    headers = [{"content-type", "application/json; charset=utf-8"}, {"cache-control", "no-store"}]

    case Request.json(request) do
      {:ok, list} when is_list(list) ->
        # Batches were in the 2025-03-26 protocol; answering them costs nothing.
        answers = list |> Enum.map(&answer(&1, read_api)) |> Enum.reject(&is_nil/1)
        if answers == [], do: Response.new(nil, 202, []), else: Response.new(JS.stringify(answers), 200, headers)

      {:ok, %Object{} = body} ->
        case answer(body, read_api) do
          nil -> Response.new(nil, 202, [])
          one -> Response.new(JS.stringify(one), 200, headers)
        end

      _ ->
        Response.new(JS.stringify(rpc_error(nil, -32700, "Send a JSON-RPC message")), 400, headers)
    end
  end
end
