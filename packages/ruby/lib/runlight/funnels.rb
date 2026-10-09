# frozen_string_literal: true

module Runlight
  # Funnels: checking one from the dashboard. Counting is the store's funnel_counts.
  module Funnels
    module_function

    # Checks and tidies a funnel from the dashboard: a name, and two to eight
    # steps, each a page (with * as a wildcard) or an event name. Gives a Hash {"id", "site", "name", "steps",
    # "createdAt"}, each step {"kind", "match"}; raises FunnelError.
    def funnel_from(input, site, existing, now, id = nil)
      name = Js.cut(Js.trim(Goals.field(input, "name")), 80)
      raise FunnelError.new("Give the funnel a name", "funnel_name") if name.empty?

      existing.each do |f|
        if f["id"] != id && Js.lower(f["name"]) == Js.lower(name)
          raise FunnelError.new("There is already a funnel called \"#{name}\"", "funnel_exists", { "name" => name })
        end
      end
      raw = Js.get(input, "steps")
      raw = [] unless raw.is_a?(Array)
      steps = []
      raw.each do |item|
        # Anything that is not an object reads as one with no fields.
        step = item.is_a?(Hash) || item.is_a?(Array) ? item : {}
        kind = Js.get(step, "kind") == "event" ? "event" : "page"
        match = Js.cut(Js.trim(Goals.field(step, "match")), 500)
        next if match.empty?

        if kind == "page"
          # A full URL is fine to paste; the path is what counts.
          path = Goals.page_pattern(match)
          raise FunnelError.new("\"#{match}\" is not a path or a URL", "funnel_page_bad", { "match" => match }) if path.nil?

          match = path
        end
        steps << { "kind" => kind, "match" => match }
      end
      raise FunnelError.new("A funnel needs at least two steps", "funnel_short") if steps.length < 2
      raise FunnelError.new("A funnel has at most eight steps", "funnel_long") if steps.length > 8

      before = existing.find { |f| f["id"] == id }
      created_at = before.nil? ? now : before["createdAt"]
      { "id" => id || Hashing.random_id, "site" => site, "name" => name, "steps" => steps, "createdAt" => created_at }
    end
  end
end
