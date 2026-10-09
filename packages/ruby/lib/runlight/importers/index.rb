# frozen_string_literal: true

module Runlight
  module Importers
    # Link imports from other shorteners, a step at a time.
    module Index
      # The sources a link import can read, by name.
      IMPORTERS = { "umami" => :Umami, "dub" => :Dub, "bitly" => :Bitly, "shortio" => :Shortio, "rebrandly" => :Rebrandly }.freeze

      module_function

      # One step of an import: fetch the next few links from the source, write
      # each with its history, and report progress. The cursor carries where to
      # pick up, so the page calls this until the cursor comes back nil.
      #
      # Each importer makes its requests through the Core's fetcher, and reads the Core's clock as its
      # `now`: the date of a link the source gives none for, and where Umami's history ends.
      #
      # Returns { "cursor", "done", "total", "links", "clicks", "skipped", "failed" }, each failure
      # { "slug", "reason", "code"?, "params"? }.
      def import_step(runlight, site, source, credentials, cursor, done)
        name = IMPORTERS[source]
        raise ImportError.new("Runlight cannot import from #{source}", "import_source", { "source" => source }) if name.nil?

        runlight.init
        importer = Importers.const_get(name).new(Client.new(runlight.fetcher), -> { runlight.now })
        known = lambda do |source_id, slug = nil, url = nil|
          return true unless runlight.store.link_by_id(Write.imported_link_id(source, Js.string(source_id))).nil?
          return false if !Js.truthy?(slug) || !Js.truthy?(url)

          taken = runlight.store.link_by_slug(Js.string(slug))
          !taken.nil? && Write.same_url(taken["url"], Js.string(url))
        end
        result = importer.step(credentials, cursor, known)
        step = { "cursor" => result["cursor"], "done" => done, "total" => result["total"], "links" => 0, "clicks" => 0, "skipped" => 0, "failed" => [] }
        result["links"].each do |item|
          if Js.truthy?(item["known"])
            step["done"] += 1
            step["skipped"] += 1
            next
          end
          written = Write.write_link(runlight, site, source, item["link"], item)
          step["done"] += 1
          case written["status"]
          when "created"
            step["links"] += 1
            step["clicks"] += written["clicks"]
          when "skipped"
            step["skipped"] += 1
          else
            failure = { "slug" => item["link"]["slug"], "reason" => written["reason"] || "" }
            failure.merge!("code" => written["code"], "params" => written["params"] || {}) if written.key?("code")
            step["failed"] << failure
          end
        end
        # Links the source skipped (deleted ones) still count toward progress.
        if (result["cursor"].nil? || result["cursor"] == "") && !result["total"].nil?
          step["done"] = [step["done"], result["total"]].max
        end
        step
      end
    end
  end
end
