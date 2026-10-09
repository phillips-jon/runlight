# frozen_string_literal: true

module Runlight
  # Goals: checking one from the dashboard, and the click rules the tracker carries.
  module Goals
    KINDS = %w[event page click].freeze
    MODES = %w[none fixed prop].freeze
    PROP = /\A[A-Za-z0-9_.-]{1,40}\z/
    private_constant :KINDS, :MODES, :PROP

    module_function

    # A page to match, written the way paths are recorded: the path of a pasted URL, with a leading slash,
    # percent-encoded as browsers send it, so /café matches the recorded /caf%C3%A9, and with a hash
    # route kept, so /#/thanks counts only that route. `*` stays a wildcard. Nil when it is not a path or a URL.
    def page_pattern(input)
      starred = input.gsub("*", "__STAR__")
      # A pattern written to start with * keeps that start, rather than gaining a slash.
      path = Sources.recorded_path(starred.start_with?("__STAR__") ? "/#{starred}" : starred)
      return nil if path.nil?

      pattern = path.gsub("__STAR__", "*")
      input.start_with?("*") ? pattern.sub(%r{\A/}, "") : pattern
    end

    # String(input[key] ?? ""), from a decoded JSON object.
    def field(input, key)
      value = Js.get(input, key)
      value.nil? || value.equal?(UNDEFINED) ? "" : Js.string(value)
    end

    # Checks and tidies a goal from the dashboard. `existing` is the site's
    # other goals, so two goals cannot share a name. Gives a goal row; raises GoalError.
    def goal_from(input, site, existing, now, id = nil)
      text = ->(key, max) { Js.cut(Js.trim(field(input, key)), max) }
      name = text.call("name", 80)
      raise GoalError.new("Give the goal a name", "goal_name") if name.empty?

      existing.each do |g|
        if g["id"] != id && Js.lower(g["name"]) == Js.lower(name)
          raise GoalError.new("There is already a goal called \"#{name}\"", "goal_exists", { "name" => name })
        end
      end

      kind = field(input, "kind")
      raise GoalError.new("Pick what the goal counts: an event, a page visit, or a click", "goal_kind") unless KINDS.include?(kind)

      match = text.call("match", 500)
      click_by = ""
      raise GoalError.new("Enter the event's name", "goal_event") if kind == "event" && match.empty?

      if kind == "page"
        raise GoalError.new("Enter a page path, like /thanks or /blog/*", "goal_page") if match.empty?

        # A full URL is fine to paste; the path is what counts.
        path = page_pattern(match)
        raise GoalError.new("That page is not a path or a URL", "goal_page_bad") if path.nil?

        match = path
      end
      if kind == "click"
        click_by = Js.get(input, "clickBy") == "link" ? "link" : "selector"
        if match.empty?
          raise(click_by == "link" ? GoalError.new("Enter the link's address, like https://buy.stripe.com/*", "goal_link")
                                    : GoalError.new("Enter a CSS selector, like #signup or .buy-button", "goal_selector"))
        end
      end

      # A click goal sends an event named after itself, so its name and an event goal's match must not meet.
      others = existing.reject { |g| g["id"] == id }
      if kind == "click"
        others.each do |g|
          next unless g["kind"] == "event" && Js.lower(g["match"]) == Js.lower(name)

          raise GoalError.new("An event goal already counts events called \"#{name}\", so give this click goal another name",
                              "goal_event_taken", { "name" => name })
        end
      end
      if kind == "event"
        others.each do |g|
          next unless g["kind"] == "click" && Js.lower(g["name"]) == Js.lower(match)

          raise GoalError.new("The click goal \"#{match}\" already sends events with that name", "goal_click_taken", { "match" => match })
        end
      end

      mode = Js.string(Js.get(input, "valueMode"))
      value_mode = MODES.include?(mode) ? mode : "none"
      # Page visits and click rules carry no properties, so only an event can send its own amount.
      if value_mode == "prop" && kind != "event"
        raise GoalError.new("Only an event goal can take its amount from the event; use a fixed amount instead", "goal_prop_kind")
      end

      value = value_mode == "fixed" ? Js.number(Js.get(input, "value")) : 0
      if value_mode == "fixed" && !(value.to_f.finite? && value >= 0 && value < 1e9)
        raise GoalError.new("Enter an amount, like 49 or 9.99", "goal_amount")
      end

      value_prop = ""
      if value_mode == "prop"
        value_prop = text.call("valueProp", 40)
        value_prop = "revenue" if value_prop.empty?
      end
      if value_mode == "prop" && !value_prop.match?(PROP)
        raise GoalError.new("A property name uses letters, numbers, dots, dashes, and underscores", "goal_prop_name")
      end

      currency = Js.upper(text.call("currency", 20))
      currency = "USD" if currency.empty?
      raise GoalError.new("Use a three-letter currency code, like USD or EUR", "goal_currency") unless currency.match?(/\A[A-Z]{3}\z/)

      before = existing.find { |g| g["id"] == id }
      rounded = Js.round(value.to_f * 100) / 100
      {
        "id" => id || Hashing.random_id,
        "site" => site,
        "name" => name,
        "kind" => kind,
        "match" => match,
        "clickBy" => click_by,
        "valueMode" => value_mode,
        # One number type in JavaScript: a whole amount is an Integer here.
        "value" => rounded == rounded.floor && rounded.abs < 2**53 ? rounded.to_i : rounded,
        "valueProp" => value_prop,
        "currency" => currency,
        "createdAt" => before.nil? || before["createdAt"].nil? ? now : before["createdAt"],
      }
    end

    # Click rules for the tracker, keyed by site id and by each of the site's
    # hostnames (or "*" for a site with none), so the script finds its own. One rule is
    # [s for selector or h for a link, what to match, the event to send].
    def click_rules(sites, goals)
      out = {}
      sites.each do |site|
        rules = goals.select { |g| g["site"] == site["id"] && g["kind"] == "click" }
                     .map { |g| [g["clickBy"] == "link" ? "h" : "s", g["match"], g["name"]] }
        next if rules.empty?

        out[site["id"]] = rules
        hosts = site["hostnames"].nil? || site["hostnames"].empty? ? ["*"] : site["hostnames"]
        hosts.each { |host| out[host.sub(/\Awww\./, "")] = rules }
      end
      out
    end
  end
end
