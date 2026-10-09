defmodule Runlight.GoalError do
  @moduledoc "Why a goal was refused, as a code the dashboard says in its own words."
  defexception [:message, :code, params: %{}]
end

defmodule Runlight.FunnelError do
  @moduledoc "Why a funnel was refused, as a code the dashboard says in its own words."
  defexception [:message, :code, params: %{}]
end

defmodule Runlight.Goals do
  @moduledoc false
  # Internal. Goals and funnels from the dashboard, checked and tidied, and
  # the tracker's click rules (the SDK's goals.ts and funnels.ts). A goal or
  # funnel is a JavaScript object in the SDK's key order.

  alias Runlight.FunnelError
  alias Runlight.GoalError
  alias Runlight.Hash
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Sources

  @kinds ["event", "page", "click"]
  @modes ["none", "fixed", "prop"]

  @doc """
  A page to match, written the way paths are recorded: the path of a pasted
  URL, with a leading slash, percent-encoded as browsers send it, so /café
  matches the recorded /caf%C3%A9, and with a hash route kept. `*` stays a
  wildcard. Nil when it is not a path or a URL.
  """
  @spec page_pattern(String.t()) :: String.t() | nil
  def page_pattern(input) do
    starred = String.replace(input, "*", "__STAR__")
    # A pattern written to start with * keeps that start, rather than gaining a slash.
    case Sources.recorded_path(if String.starts_with?(starred, "__STAR__"), do: "/" <> starred, else: starred) do
      nil ->
        nil

      path ->
        pattern = String.replace(path, "__STAR__", "*")
        if String.starts_with?(input, "*"), do: String.replace(pattern, ~r/^\//, ""), else: pattern
    end
  end

  @dialyzer {:nowarn_function, refuse: 2}
  defp refuse(message, code, params \\ %{}), do: raise(GoalError, message: message, code: code, params: params)

  defp text(input, key, max),
    do: input |> JS.prop(key) |> JS.nullish("") |> JS.string() |> JS.trim() |> JS.slice(0, max)

  @doc """
  Checks and tidies a goal from the dashboard. `existing` is the site's other
  goals, so two goals cannot share a name. Raises GoalError.
  """
  @spec goal_from(Object.t(), String.t(), [Object.t()], integer(), String.t() | nil) :: Object.t()
  def goal_from(input, site, existing, now, id \\ nil) do
    name = text(input, "name", 80)
    if name == "", do: refuse("Give the goal a name", "goal_name")

    if Enum.any?(existing, &(&1["id"] != id and JS.lower(&1["name"]) == JS.lower(name))),
      do: refuse(~s(There is already a goal called "#{name}"), "goal_exists", %{"name" => name})

    kind = input |> JS.prop("kind") |> JS.nullish("") |> JS.string()
    unless kind in @kinds, do: refuse("Pick what the goal counts: an event, a page visit, or a click", "goal_kind")

    match = text(input, "match", 500)
    if kind == "event" and match == "", do: refuse("Enter the event's name", "goal_event")

    match =
      if kind == "page" do
        if match == "", do: refuse("Enter a page path, like /thanks or /blog/*", "goal_page")
        # A full URL is fine to paste; the path is what counts.
        page_pattern(match) || refuse("That page is not a path or a URL", "goal_page_bad")
      else
        match
      end

    click_by =
      if kind == "click" do
        by = if JS.prop(input, "clickBy") == "link", do: "link", else: "selector"

        if match == "" do
          if by == "link",
            do: refuse("Enter the link's address, like https://buy.stripe.com/*", "goal_link"),
            else: refuse("Enter a CSS selector, like #signup or .buy-button", "goal_selector")
        end

        by
      else
        ""
      end

    # A click goal sends an event named after itself, so its name and an event goal's match must not meet.
    others = Enum.filter(existing, &(&1["id"] != id))

    if kind == "click" and Enum.any?(others, &(&1["kind"] == "event" and JS.lower(&1["match"]) == JS.lower(name))) do
      refuse(
        ~s(An event goal already counts events called "#{name}", so give this click goal another name),
        "goal_event_taken",
        %{"name" => name}
      )
    end

    if kind == "event" and Enum.any?(others, &(&1["kind"] == "click" and JS.lower(&1["name"]) == JS.lower(match))) do
      refuse(~s(The click goal "#{match}" already sends events with that name), "goal_click_taken", %{"match" => match})
    end

    mode = input |> JS.prop("valueMode") |> JS.string()
    mode = if mode in @modes, do: mode, else: "none"

    # Page visits and click rules carry no properties, so only an event can send its own amount.
    if mode == "prop" and kind != "event",
      do: refuse("Only an event goal can take its amount from the event; use a fixed amount instead", "goal_prop_kind")

    value = if mode == "fixed", do: JS.number(JS.prop(input, "value")), else: 0

    if mode == "fixed" and not (JS.finite?(value) and value >= 0 and value < 1.0e9),
      do: refuse("Enter an amount, like 49 or 9.99", "goal_amount")

    value_prop = if mode == "prop", do: JS.or_else(text(input, "valueProp", 40), "revenue"), else: ""

    if mode == "prop" and not Regex.match?(~r/\A[A-Za-z0-9_.-]{1,40}\z/, value_prop),
      do: refuse("A property name uses letters, numbers, dots, dashes, and underscores", "goal_prop_name")

    currency = JS.or_else(JS.upper(text(input, "currency", 20)), "USD")

    unless Regex.match?(~r/\A[A-Z]{3}\z/, currency),
      do: refuse("Use a three-letter currency code, like USD or EUR", "goal_currency")

    before = Enum.find(existing, &(&1["id"] == id))

    JS.obj(
      id: id || Hash.random_id(),
      site: site,
      name: name,
      kind: kind,
      match: match,
      clickBy: click_by,
      valueMode: mode,
      value: JS.normalize(JS.round(value * 100) / 100),
      valueProp: value_prop,
      currency: currency,
      createdAt: if(before, do: before["createdAt"], else: now)
    )
  end

  @doc """
  Click rules for the tracker, keyed by site id and by each of the site's
  hostnames (or "*" for a site with none), so the script finds its own. Each
  rule is [s for a selector or h for a link, what to match, the event to send].
  """
  @spec click_rules([Object.t()], [Object.t()]) :: Object.t()
  def click_rules(sites, goals) do
    Enum.reduce(sites, Object.new(), fn site, out ->
      rules =
        for g <- goals, g["site"] == site["id"] and g["kind"] == "click" do
          [if(g["clickBy"] == "link", do: "h", else: "s"), g["match"], g["name"]]
        end

      if rules == [] do
        out
      else
        out = Object.put(out, site["id"], rules)
        hosts = if site["hostnames"] == [], do: ["*"], else: site["hostnames"]
        Enum.reduce(hosts, out, fn host, out -> Object.put(out, String.replace(host, ~r/^www\./, ""), rules) end)
      end
    end)
  end

  @doc """
  Checks and tidies a funnel from the dashboard: a name, and two to eight
  steps, each a page (with * as a wildcard) or an event name. Raises
  FunnelError.
  """
  @spec funnel_from(Object.t(), String.t(), [Object.t()], integer(), String.t() | nil) :: Object.t()
  def funnel_from(input, site, existing, now, id \\ nil) do
    name = text(input, "name", 80)
    if name == "", do: raise(FunnelError, message: "Give the funnel a name", code: "funnel_name")

    if Enum.any?(existing, &(&1["id"] != id and JS.lower(&1["name"]) == JS.lower(name))),
      do:
        raise(FunnelError,
          message: ~s(There is already a funnel called "#{name}"),
          code: "funnel_exists",
          params: %{"name" => name}
        )

    raw = if is_list(JS.prop(input, "steps")), do: JS.prop(input, "steps"), else: []

    steps =
      Enum.flat_map(raw, fn item ->
        step = if JS.objectish?(item), do: item, else: Object.new()
        kind = if JS.prop(step, "kind") == "event", do: "event", else: "page"
        match = text(step, "match", 500)

        cond do
          match == "" ->
            []

          kind == "page" ->
            case page_pattern(match) do
              nil ->
                raise FunnelError,
                  message: ~s("#{match}" is not a path or a URL),
                  code: "funnel_page_bad",
                  params: %{"match" => match}

              path ->
                [JS.obj(kind: kind, match: path)]
            end

          true ->
            [JS.obj(kind: kind, match: match)]
        end
      end)

    if length(steps) < 2, do: raise(FunnelError, message: "A funnel needs at least two steps", code: "funnel_short")
    if length(steps) > 8, do: raise(FunnelError, message: "A funnel has at most eight steps", code: "funnel_long")

    before = Enum.find(existing, &(&1["id"] == id))

    JS.obj(
      id: id || Hash.random_id(),
      site: site,
      name: name,
      steps: steps,
      createdAt: if(before, do: before["createdAt"], else: now)
    )
  end
end
