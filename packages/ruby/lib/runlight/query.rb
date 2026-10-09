# frozen_string_literal: true

module Runlight
  # Report queries: which dimensions exist, where each lives, and how filters
  # are read from a URL. Shared by every store.
  #
  # A filter is a Hash {"dimension", "op" ("is", "not", or "contains"), "value"}. A query is a Hash {"site",
  # "from", "to", "filters"}, `from` inclusive and `to` exclusive, both epoch milliseconds.
  module Query
    # Dimensions recorded per event.
    EVENT_DIMENSIONS = {
      "page" => "path",
      "hostname" => "hostname",
      "event" => "name",
    }.freeze

    # Dimensions recorded once per session, from its first request.
    SESSION_DIMENSIONS = {
      "entry" => "entry_path",
      "exit" => "exit_path",
      "referrer" => "referrer_host",
      "source" => "source",
      "channel" => "channel",
      "utm_source" => "utm_source",
      "utm_medium" => "utm_medium",
      "utm_campaign" => "utm_campaign",
      "utm_term" => "utm_term",
      "utm_content" => "utm_content",
      "country" => "country",
      "region" => "region",
      "city" => "city",
      "browser" => "browser",
      "browser_version" => "browser_version",
      "os" => "os",
      "os_version" => "os_version",
      "device" => "device",
      "screen" => "screen",
      "language" => "language",
    }.freeze

    # AI agent fetches are their own rows, outside visits.
    FETCH_DIMENSIONS = %w[ai_agent ai_page].freeze

    # Every dimension: the event ones, the session ones, then the fetch ones.
    DIMENSIONS = %w[
      page hostname event
      entry exit referrer source channel utm_source utm_medium utm_campaign utm_term utm_content
      country region city browser browser_version os os_version device screen language
      ai_agent ai_page
    ].freeze

    # The most filters a query takes, which keeps every statement within Cloudflare D1's 100 values.
    MAX_FILTERS = 6

    module_function

    def dimension?(value)
      DIMENSIONS.include?(value)
    end

    def session_dimension?(value)
      SESSION_DIMENSIONS.key?(value)
    end

    def event_dimension?(value)
      EVENT_DIMENSIONS.key?(value)
    end

    # `dimension:op:value`, where the value may itself contain colons. A Hash {"dimension", "op", "value"}, or nil.
    def parse_filter(text)
      dimension, op, value = text.split(":", 3)
      return nil if value.nil?
      return nil if !session_dimension?(dimension) && !event_dimension?(dimension)
      return nil if op != "is" && op != "not" && op != "contains"

      { "dimension" => dimension, "op" => op, "value" => Js.slice(value, 0, 500) }
    end
  end
end
