# frozen_string_literal: true

module Runlight
  # Journeys: the paths visits take through a site, page by page. Each visit's
  # pages are read in order, a page seen twice in a row (a refresh) counts once,
  # and the path is cut to a number of steps, from a start page and to an end
  # page when those are chosen. The answer lines the paths up in columns, one
  # per step, with the flows between them, as Umami's journeys do.
  #
  # Options: "steps", and optionally "start", "end", and "through" ({"step", "value"}: only paths that show this
  # page at this step, 0-based, to follow one page).
  #
  # The answer: "visits"; "columns", each with "items" (the pages seen at this step, most visits first, with the
  # rest as "" for other pages), "visits" (that reached this step), and "left" (that went no further); "links",
  # visits moving from a page at one step to a page at the next, "" being any other page; and "paths", the
  # commonest whole paths.
  module Journeys
    # How many pages of a visit to read: enough to find a start page and still have the steps after it.
    PAGES_PER_VISIT = 40
    TOP = 8
    private_constant :TOP

    module_function

    # rows: an Enumerable of Hashes {"session", "path"}.
    def journeys(rows, options)
      wanted = (options["steps"] || Float::NAN).to_f
      floor = wanted.finite? ? wanted.floor.to_f : wanted
      steps = (floor.nan? || floor.zero? ? 5 : floor).clamp(2, 8).to_i
      # Group each visit's pages, dropping refreshes.
      visits = {}
      rows.each do |row|
        pages = (visits[row["session"]] ||= [])
        pages << row["path"] if pages.empty? || pages[-1] != row["path"]
      end
      start = options["start"]
      finish = options["end"]
      through = options["through"]
      sequences = []
      # Visits that went on past the last step shown, so they never count as having gone no further.
      cut = []
      visits.each_value do |pages|
        if !start.nil? && start != ""
          at = pages.index(start)
          next if at.nil?

          pages = pages[at..]
        end
        if !finish.nil? && finish != ""
          at = pages.index(finish)
          next if at.nil?

          pages = pages[0..at]
        end
        more = pages.length > steps
        pages = pages.first(steps)
        next if !through.nil? && at(pages, through["step"]) != through["value"]

        cut << more
        sequences << pages
      end

      columns = []
      kept = []
      steps.times do |i|
        counts = {}
        reached = 0
        left = 0
        sequences.each_with_index do |s, n|
          next if s.length <= i

          reached += 1
          left += 1 if s.length == i + 1 && !cut[n]
          counts[s[i]] = (counts[s[i]] || 0) + 1
        end
        sorted = counts.to_a.sort { |a, b| (b[1] <=> a[1]).nonzero? || (Js.compare(a[0], b[0]).negative? ? -1 : 1) }
        top = sorted.first(TOP)
        rest = sorted.drop(TOP).sum { |_, v| v }
        kept << top.to_h { |value, _| [value, true] }
        break if reached.zero?

        items = top.map { |value, count| { "value" => value, "visits" => count } }
        items << { "value" => "", "visits" => rest } if rest.positive?
        columns << { "items" => items, "visits" => reached, "left" => left }
      end

      link_counts = {}
      sequences.each do |s|
        i = 0
        while i + 1 < s.length && i + 1 < columns.length
          from = kept[i].key?(s[i]) ? s[i] : ""
          to = kept[i + 1].key?(s[i + 1]) ? s[i + 1] : ""
          link = (link_counts[[i, from, to]] ||= { "step" => i, "from" => from, "to" => to, "visits" => 0 })
          link["visits"] += 1
          i += 1
        end
      end
      # Ties go by page, as the columns and paths do, so the order never follows the visits' random ids.
      links = link_counts.values.sort do |a, b|
        (a["step"] <=> b["step"]).nonzero? || (b["visits"] <=> a["visits"]).nonzero? ||
          Js.compare(a["from"], b["from"]).nonzero? || Js.compare(a["to"], b["to"])
      end

      path_counts = {}
      sequences.each do |s|
        key = s.join("\0")
        path = (path_counts[key] ||= { "key" => key, "pages" => s, "visits" => 0 })
        path["visits"] += 1
      end
      paths = path_counts.values.sort do |x, y|
        (y["visits"] <=> x["visits"]).nonzero? || (Js.compare(x["key"], y["key"]).negative? ? -1 : 1)
      end
      paths = paths.first(20).map { |p| { "pages" => p["pages"], "visits" => p["visits"] } }

      { "visits" => sequences.length, "columns" => columns, "links" => links, "paths" => paths }
    end

    # pages[step], which is undefined (nil) for a step that is not a whole number in range.
    def at(pages, step)
      return nil unless step.is_a?(Integer) || step.is_a?(Float)
      return nil if step.is_a?(Float) && (!step.finite? || step != step.floor)

      step = step.to_i
      step.negative? ? nil : pages[step]
    end

    private_class_method :at
  end
end
