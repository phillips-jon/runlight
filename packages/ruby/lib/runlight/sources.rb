# frozen_string_literal: true

module Runlight
  # Pages and where visits came from.
  #
  # A page is a Hash {"hostname", "path", "utm" => {"source", "medium", "campaign", "term", "content"}, "ref",
  # "paid"}: `ref` is a `ref` or `source` query parameter, used when there is no utm_source, and `paid` says a
  # click id such as gclid was present (the id itself is never kept). An attribution is a Hash {"referrerHost",
  # "referrerPath", "source", "channel"}, the channel one of Direct, Organic Search, Paid Search, Social, Email,
  # AI, Referral, or Campaign.
  module Sources
    CLICK_IDS = %w[gclid gbraid wbraid dclid fbclid msclkid ttclid twclid li_fat_id yclid].freeze
    PAID_MEDIUMS = /\A(cpc|ppc|paid|paidsearch|paid_search|paid-search|sem|cpm|cpv|display|banner|retargeting)\z/
    EMAIL_MEDIUMS = /\A(e-?mail|newsletter|mail)\z/
    SOCIAL_MEDIUMS = /\A(social|social-network|social-media|sm|social_network|social_media|paid_social|paid-social|paidsocial)\z/
    # Text that would change a path's meaning if it were shown decoded: white space, a slash, ?, #, %, or any
    # control, format, unassigned, or private use character.
    MEANINGFUL = %r{[#{Js::SPACE}/?#%]|\p{C}}
    private_constant :CLICK_IDS, :PAID_MEDIUMS, :EMAIL_MEDIUMS, :SOCIAL_MEDIUMS, :MEANINGFUL

    @by_host = nil
    @by_alias = {}

    module_function

    def maps
      return unless @by_host.nil?

      # Later entries win, as Map.set does: the alias "kit" names Newsletter, not Kit.
      by_host = {}
      Data::Sources::SOURCES.each do |source|
        source["hosts"].each { |host| by_host[host] = source }
        (source["aliases"] || []).each { |name| @by_alias[name] = source }
      end
      @by_host = by_host
    end

    def clip(value, max = 200)
      Js.slice(Js.trim(value || ""), 0, max)
    end

    def strip_www(host)
      lower = Js.lower(host)
      lower.start_with?("www.") ? lower[4..] : lower
    end

    # The most specific known source for a host: mail.google.com before
    # google.com. Android apps send their package name as the referrer
    # (com.google.android.gm for Gmail), which is matched the same way. Hosts
    # known only by their shape (click trackers, webmail) come last.
    def source_for_host(host)
      maps
      clean = strip_www(host)
      candidate = clean
      while candidate.include?(".")
        found = @by_host[candidate]
        return found unless found.nil?

        candidate = candidate[(candidate.index(".") + 1)..]
      end
      Data::Sources::SOURCE_PATTERNS.each do |rule|
        return { "name" => rule["name"] || clean, "kind" => rule["kind"], "hosts" => [] } if clean.match?(rule["pattern"])
      end
      nil
    end

    def source_for_alias(value)
      maps
      key = Js.trim(Js.lower(value))
      @by_alias[key] || @by_host[strip_www(key)]
    end

    # A path a person wrote, in the form paths are recorded: the path of a pasted URL, with a leading
    # slash, percent-encoded as the browser's URL parser encodes it, and with a hash route kept, as
    # parse_page keeps it. Nil when it is not a path or a URL.
    def recorded_path(input)
      url = if input.b.match?(%r{\Ahttps?://}in)
              Http::Url.parse(input)
            else
              Http::Url.parse(input.start_with?("/") ? input : "/#{input}", "https://x.invalid")
            end
      url.nil? ? nil : parse_page(url)["path"]
    end

    # A recorded path as people write it, for showing and exporting: /caf%C3%A9 as /café. Only text is
    # decoded; an encoded slash, space, or other mark that would change the path's meaning stays as it is.
    def readable_path(path)
      Js.scrub(path).gsub(/(?:%[0-9A-Fa-f]{2})+/) do |run|
        text = Js.decode_uri_component(run)
        text.nil? || text.match?(MEANINGFUL) ? run : text
      end
    end

    def parse_page(url)
      q = url.search_params
      path = url.pathname.empty? ? "/" : url.pathname
      # The tracker only sends a hash when the site asked for hash routing.
      path += url.hash if Js.length(url.hash) > 1
      paid = CLICK_IDS.any? { |id| q.has?(id) }
      {
        "hostname" => strip_www(url.hostname),
        "path" => Js.slice(path, 0, 1000),
        "utm" => {
          "source" => clip(q.get("utm_source")),
          "medium" => Js.lower(clip(q.get("utm_medium"))),
          "campaign" => clip(q.get("utm_campaign")),
          "term" => clip(q.get("utm_term")),
          "content" => clip(q.get("utm_content")),
        },
        "ref" => clip(q.get("ref") || q.get("source")),
        "paid" => paid,
      }
    end

    # Where a visit came from. `internal_hosts` are the site's own hostnames: a
    # referrer on one of them is navigation within the site, not a source.
    def attribute(page, referrer, internal_hosts)
      referrer_host = ""
      referrer_path = ""
      unless referrer.empty?
        # Not a URL is treated as no referrer.
        url = Http::Url.parse(referrer)
        # Android apps refer as android-app://<package>/.
        if !url.nil? && ["http:", "https:", "android-app:"].include?(url.protocol)
          host = strip_www(url.hostname)
          if host != page["hostname"] && !internal_hosts.include?(host)
            referrer_host = host
            referrer_path = url.protocol == "android-app:" ? "" : Js.slice(url.pathname, 0, 500)
          end
        end
      end

      tagged = page["utm"]["source"] == "" ? page["ref"] : page["utm"]["source"]
      known = if tagged != "" then source_for_alias(tagged)
              elsif referrer_host != "" then source_for_host(referrer_host)
              end
      source = known ? known["name"] : (tagged == "" ? referrer_host : tagged)
      kind = if known then known["kind"]
             elsif referrer_host != "" then source_for_host(referrer_host)&.fetch("kind")
             end
      medium = page["utm"]["medium"]

      channel =
        if (page["paid"] || medium.match?(PAID_MEDIUMS)) && kind == "search" then "Paid Search"
        elsif kind == "ai" then "AI"
        elsif medium.match?(EMAIL_MEDIUMS) || kind == "email" then "Email"
        elsif kind == "search" then "Organic Search"
        elsif medium.match?(SOCIAL_MEDIUMS) || kind == "social" then "Social"
        elsif page["utm"]["source"] != "" || page["utm"]["medium"] != "" || page["utm"]["campaign"] != "" then "Campaign"
        elsif referrer_host != "" || page["ref"] != "" then "Referral"
        else "Direct"
        end

      { "referrerHost" => referrer_host, "referrerPath" => referrer_path, "source" => source, "channel" => channel }
    end

    private_class_method :maps, :clip
  end
end
