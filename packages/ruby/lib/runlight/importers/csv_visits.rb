# frozen_string_literal: true

module Runlight
  module Importers
    # Visit history from a CSV file, in one of two shapes: Umami's data export
    # (one row per pageview or event, as in its website_event table) or Runlight's
    # own, documented on the dashboard docs page. The dashboard reads the file,
    # sorts it with row_time, and sends it in batches; the server turns each row
    # into a hit with csv_hit. Nothing here touches a database.
    #
    # A format is "umami" or "runlight". A hit is an ImportedHit Hash (see Visits).
    module CsvVisits
      # At most this many rows in one request.
      CSV_BATCH = 2000

      SCHEME = %r{\A[a-z][a-z0-9+.-]*://}i
      private_constant :SCHEME

      module_function

      # Which shape a file is, from its header row (lower case, as the dashboard reads it).
      def csv_format(columns)
        return "umami" if columns.include?("created_at") && columns.include?("url_path")
        return "runlight" if columns.include?("time") && (columns.include?("path") || columns.include?("url"))

        nil
      end

      # A row's time in milliseconds, or NaN. ISO 8601 with or without a zone, "2024-05-01 12:34:56"
      # (both read as UTC when no zone is given, as Umami writes them), or a Unix time in seconds or milliseconds.
      def row_time(row, format)
        text = Js.trim((format == "umami" ? row["created_at"] : row["time"]) || "")
        return Float::NAN if text.empty?

        if text.match?(/\A\d+(\.\d+)?\z/)
          n = text.to_f
          ms = n < 1e12 ? Js.round(n * 1000) : Js.round(n)
          return ms.abs < 2**53 ? ms.to_i : ms
        end
        iso = text.sub(" ", "T")
        Client.parse_date(iso.match?(/[zZ]|[+-]\d\d:?\d\d\z/) || !iso.match?(/T\d/) ? iso : "#{iso}Z")
      end

      def cell(row, *names)
        names.each do |n|
          return Js.trim(row[n]) if !row[n].nil? && Js.trim(row[n]) != ""
        end
        ""
      end

      # A row with no visitor is its own visit, keyed by its whole content so a second import gives it the same ids.
      def own_key(row)
        entries = row.map { |k, v| [k.to_s, v] }
        entries = entries.sort { |a, b| Js.compare(a[0], b[0]).negative? ? -1 : 1 }
        "row:#{Json.encode(entries)}"
      end

      # A referrer as a full address: a bare domain gains https://.
      def full_referrer(value)
        return "" if value == ""

        value.match?(SCHEME) ? value : "https://#{value}"
      end

      # One row as a hit and the namespace its ids are made in, or nil for a row that is not a pageview or a
      # named event, or has no time. Umami rows use the namespace the Umami API import does, so the same visits
      # brought in both ways get the same ids. Returns { "ns", "hit" }.
      def csv_hit(row, format)
        ts = row_time(row, format)
        return nil if ts.is_a?(Float) && !ts.finite?

        if format == "umami"
          type = cell(row, "event_type")
          type = "1" if type.empty?
          name = cell(row, "event_name")
          return nil if type != "1" && !(type == "2" && name != "")

          website = cell(row, "website_id")
          domain = cell(row, "referrer_domain")
          query = cell(row, "referrer_query")
          referrer_path = cell(row, "referrer_path")
          key = cell(row, "session_id", "visit_id")
          path = cell(row, "url_path")
          referrer = if domain.empty? then ""
                     else "https://#{domain}#{referrer_path.empty? ? "/" : referrer_path}#{query.empty? ? "" : "?#{query.sub(/\A\?/, "")}"}"
                     end
          return {
            "ns" => website.empty? ? "umami-csv" : "umami-visits:#{website}",
            "hit" => {
              "ts" => ts,
              "key" => key.empty? ? own_key(row) : key,
              "kind" => type == "1" ? "pageview" : "event",
              "hostname" => cell(row, "hostname"),
              "path" => path.empty? ? "/" : path,
              "query" => cell(row, "url_query"),
              "referrer" => referrer,
              "title" => cell(row, "page_title"),
              "name" => type == "2" ? name : "",
              "country" => cell(row, "country"),
              "region" => cell(row, "subdivision1", "region"),
              "city" => cell(row, "city"),
              "browser" => cell(row, "browser"),
              "os" => cell(row, "os"),
              "device" => cell(row, "device"),
              "screen" => cell(row, "screen"),
              "language" => cell(row, "language"),
            },
          }
        end
        # Runlight's own shape: a full url, or a path (with its query) and a hostname.
        hostname = cell(row, "hostname")
        path = cell(row, "path")
        query = ""
        url = cell(row, "url")
        if url.empty?
          at = path.index("?")
          path, query = path[0, at], path[(at + 1)..] unless at.nil?
        else
          u = Http::Url.parse(url.match?(SCHEME) ? url : "https://#{url}")
          return nil if u.nil?

          hostname = u.hostname if hostname.empty?
          path = u.pathname
          query = u.search.empty? ? "" : u.search[1..]
        end
        path = "/#{path}" unless path.start_with?("/")
        name = cell(row, "event")
        visitor = cell(row, "visitor")
        {
          "ns" => "csv",
          "hit" => {
            "ts" => ts,
            # Without a visitor column every row is its own visit.
            "key" => visitor.empty? ? own_key(row) : visitor,
            "kind" => name.empty? ? "pageview" : "event",
            "hostname" => hostname,
            "path" => path,
            "query" => query,
            "referrer" => full_referrer(cell(row, "referrer")),
            "title" => cell(row, "title"),
            "name" => name,
            "country" => cell(row, "country"),
            "region" => cell(row, "region"),
            "city" => cell(row, "city"),
            "browser" => cell(row, "browser"),
            "os" => cell(row, "os"),
            "device" => cell(row, "device"),
            "screen" => cell(row, "screen"),
            "language" => cell(row, "language"),
          },
        }
      end

      private_class_method :cell, :own_key, :full_referrer
    end
  end
end
