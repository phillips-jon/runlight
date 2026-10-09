# frozen_string_literal: true

require "securerandom"

module Runlight
  # Short links: create, change, delete, and import, with the rules every route shares.
  #
  # A LinkInput is a Hash with "url", and optionally "name", "slug", and "domain" (a link domain added in
  # Settings, or "" for the app's own). A key left out is TS's undefined.
  class Links
    SLUG_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,99}\z/
    ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"
    private_constant :ALPHABET

    def initialize(runlight)
      @runlight = runlight
    end

    # Six characters from an alphabet without look-alikes (no 0/o, 1/l).
    def self.random_slug
      SecureRandom.random_bytes(6).bytes.map { |byte| ALPHABET[byte % ALPHABET.length] }.join
    end

    def create(site, input)
      input = Options.normalize(input)
      @runlight.init
      url = clean_url(input["url"])
      domain = domain_for(site, input["domain"])
      slug = free_slug(input["slug"].nil? ? nil : Js.trim(Js.string(input["slug"])))
      now = @runlight.now
      name = input["name"].nil? ? "" : Js.trim(Js.string(input["name"]))
      link = {
        "id" => Hashing.random_id,
        "site" => site,
        "domain" => domain,
        "slug" => slug,
        "name" => Js.slice(name == "" ? default_name(url) : name, 0, 100),
        "url" => url,
        "createdAt" => now,
        "updatedAt" => now,
      }
      @runlight.store.insert_link(link)
      link
    end

    # Keys left out of `input` are left alone.
    def update(id, input)
      input = Options.normalize(input)
      @runlight.init
      link = @runlight.store.link_by_id(id)
      raise RangeError, "Unknown link" if link.nil?

      nxt = link.dup
      nxt["url"] = clean_url(input["url"]) if input.key?("url")
      if input.key?("name")
        name = Js.slice(Js.trim(Js.string(input["name"])), 0, 100)
        nxt["name"] = name == "" ? default_name(nxt["url"]) : name
      end
      # Keeping a link's domain needs no check, even while that domain is removed.
      if input.key?("domain") && Sources.strip_www(Js.trim(Js.string(input["domain"]))) != link["domain"]
        nxt["domain"] = domain_for(link["site"], input["domain"])
      end
      nxt["slug"] = free_slug(Js.trim(Js.string(input["slug"])), link["id"]) if input.key?("slug")
      nxt["updatedAt"] = @runlight.now
      @runlight.store.update_link(nxt)
      nxt
    end

    def remove(id)
      @runlight.init
      raise RangeError, "Unknown link" if @runlight.store.link_by_id(id).nil?

      @runlight.store.delete_link(id, @runlight.now)
      nil
    end

    # Creates many links at once, as from a CSV. Rows that fail are reported
    # with their reason and the rest go in. Headers match the Umami fork's
    # export: name or link_name, url or destination_url, slug or link_slug,
    # domain or tracking_domain. Gives { "created", "failed" => [{ "row", "reason", "code", "params" }] }.
    def import(site, rows)
      failed = []
      created = 0
      rows.to_a.each_with_index do |raw, i|
        raw = {} unless raw.is_a?(Hash)
        pick = lambda do |*keys|
          keys.each do |key|
            value = raw[key]
            return Js.trim(value) if value.is_a?(String) && Js.trim(value) != ""
          end
          nil
        end
        input = { "url" => pick.call("url", "destination_url") || "" }
        { "name" => %w[name link_name], "slug" => %w[slug link_slug], "domain" => %w[domain tracking_domain] }.each do |field, keys|
          value = pick.call(*keys)
          input[field] = value unless value.nil?
        end
        begin
          create(site, input)
          created += 1
        rescue LinkError => e
          # A bad row is reported and skipped; a failing database stops the whole import.
          failed << { "row" => i + 1, "reason" => e.message, "code" => e.code, "params" => e.params || {} }
        end
      end
      { "created" => created, "failed" => failed }
    end

    private

    def clean_url(value)
      text = Js.trim(Js.string(value.nil? ? "" : value))
      url = Http::Url.parse(text)
      raise LinkError.new("The destination must be a full URL, starting with https://", "link_url") if url.nil?
      if url.protocol != "https:" && url.protocol != "http:"
        raise LinkError.new("The destination must start with http:// or https://", "link_protocol")
      end
      raise LinkError.new("The destination is longer than 2,000 characters", "link_long") if Js.length(text) > 2000

      url.href
    end

    def default_name(url)
      u = Http::Url.new(url)
      Js.slice(Sources.strip_www(u.hostname) + (u.pathname == "/" ? "" : u.pathname), 0, 100)
    end

    def domain_for(site, value)
      domain = Sources.strip_www(Js.trim(Js.string(value.nil? ? "" : value)))
      return "" if domain == ""
      return domain if @runlight.store.link_domains.any? { |d| d["domain"] == domain && d["site"] == site }

      raise LinkError.new("Add #{domain} as a link domain in Settings first", "link_domain", { "domain" => domain })
    end

    # Slugs are unique across every domain, so a link can always fall back to the app's own path.
    def free_slug(wanted, except = nil)
      if !wanted.nil? && wanted != ""
        unless wanted.match?(SLUG_PATTERN)
          raise LinkError.new("A slug is letters, digits, dashes, and underscores, up to 100", "link_slug")
        end

        taken = @runlight.store.link_by_slug(wanted)
        raise LinkError.new("/#{wanted} is already taken", "link_taken", { "slug" => wanted }) if !taken.nil? && taken["id"] != except

        return wanted
      end
      8.times do
        slug = self.class.random_slug
        return slug if @runlight.store.link_by_slug(slug).nil?
      end
      raise LinkError.new("Could not find a free slug; try again", "link_no_slug")
    end
  end
end
