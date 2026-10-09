# frozen_string_literal: true

require "openssl"
require_relative "normalizer"
require_relative "scenarios"
require_relative "upstream_fetcher"
require_relative "zip"

module Conformance
  # Plays a scenario from conformance/http.json exactly as play() in
  # packages/sdk/test/http-conformance.ts does, and returns each step's answer,
  # normalized, in the shape of the file's `expect`: Hashes with status,
  # headers, body, text, files, found, fetched, or pass.
  #
  # The scenario's options become the Ruby options the port conventions name,
  # and a Target (the core, or a fake) takes the requests. Keep this file in step
  # with the TypeScript runner: FORMAT_SHA256 fails a test when the file's
  # description of the format changes.
  class Player
    # The SHA-256 of http.json's description this runner was written against.
    FORMAT_SHA256 = "87a6f2d7f8acd8026aa4c9ede697d21457a0b9c1a2bfc01488aa2d9598def68f"

    # Environment the SDK reads defaults from, cleared while a scenario plays so nothing outside it counts.
    ENV_NAMES = %w[RUNLIGHT_TOKEN RUNLIGHT_SECRET CRON_SECRET RUNLIGHT_OBSERVE_KEY NODE_ENV].freeze

    # The content type JavaScript's Request gives a string body sent with none, which the TypeScript answers
    # were made with.
    TEXT_BODY_TYPE = "text/plain;charset=UTF-8"

    BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    # The clock, in epoch milliseconds, as the scenario's steps move it.
    attr_reader :now

    def initialize
      @now = 0
    end

    # Runs a scenario's steps and returns each answer, normalized.
    #
    # scenario: one of http.json's scenarios, as Json.decode gives it. make_target: called with the Core
    # options and the routes options, returns the Target. store: the Core's "store" option, left out when nil.
    # keep_going: a step that raises answers {"raised" => "Class: message (where)"} and the scenario plays on,
    # where by default the error ends it, naming the step.
    def play(scenario, make_target, store = nil, keep_going: false)
      saved = self.class.clear_env
      begin
        steps(scenario, make_target, store, UpstreamFetcher.new(scenario["upstream"] || []), keep_going)
      ensure
        self.class.restore_env(saved)
      end
    end

    # The options Runlight::Core.new gets, without the store, the clock, and the fetcher.
    def self.runlight_options(scenario)
      options = scenario["options"] || {}
      out = {}
      if filled?(options["managedSites"])
        out["managedSites"] = true
      elsif !scenario["sites"].nil?
        out["sites"] = plain(scenario["sites"])
      else
        out["site"] = plain(scenario["site"])
      end
      out["secret"] = options["secret"] if !options["secret"].nil? && options["secret"] != ""
      out["rateLimit"] = options["rateLimit"] if options.key?("rateLimit")
      out
    end

    # The options core.routes gets. The token is always there: a string, "" for none, or nil to leave the
    # routes open, never left out, which would read RUNLIGHT_TOKEN.
    def self.routes_options(scenario)
      options = scenario["options"] || {}
      out = {
        "token" => scenario["token"],
        "observeKey" => options["observeKey"].nil? ? "" : options["observeKey"],
        "cronSecret" => options["cronSecret"].nil? ? "" : options["cronSecret"],
      }
      out["accounts"] = true if filled?(options["accounts"])
      out["origin"] = options["origin"] if filled?(options["origin"])
      out
    end

    # A value kept from an answer: a dotted path into its JSON body, header:<name>, text, or fetched, any of
    # them followed by ~<regex> to keep the regex's first group instead. Read before normalizing.
    def self.capture(spec, answer, text, parsed, sent_out)
      source, pattern = spec.split("~", 2)
      value =
        if source == "text"
          text
        elsif source == "fetched"
          sent_out.map { |f| f["text"] }.join("\n")
        elsif source.start_with?("header:")
          header = source.delete_prefix("header:").downcase
          header == "set-cookie" ? answer.headers.get_set_cookie.join("\n") : (answer.headers.get(header) || "")
        else
          js_string(dig(parsed, source))
        end
      pattern.nil? ? value : first_group(pattern, value)
    end

    # `new RegExp(pattern).exec(value)?.[1] ?? ""`.
    def self.first_group(pattern, value)
      regex = begin
        Regexp.new(pattern)
      rescue RegexpError
        raise ArgumentError, "The capture pattern #{pattern} is not one Ruby reads"
      end
      Runlight::Js.scrub(value).match(regex)&.[](1) || ""
    end

    # `path.split(".").reduce((v, k) => (v && typeof v === "object" ? v[k] : undefined), value)`.
    def self.dig(value, path)
      path.split(".", -1).each do |k|
        case value
        when Hash then value = value.key?(k) ? value[k] : nil
        when Array then value = k.match?(/\A\d+\z/) && k.to_i.to_s == k ? value[k.to_i] : nil
        else return nil
        end
      end
      value
    end

    # `String(value ?? "")`, as JavaScript writes a JSON value as text.
    def self.js_string(value)
      case value
      when nil then ""
      when String then value
      when true then "true"
      when false then "false"
      when Integer, Float then Runlight::Json.number(value)
      when Array then value.map { |v| js_string(v) }.join(",")
      else "[object Object]"
      end
    end

    # The six-digit TOTP code (RFC 6238: SHA-1, base32 secret) for this time step, as auth.ts makes it.
    def self.totp(secret, step)
      key = unbase32(secret)
      mac = OpenSSL::HMAC.digest("SHA1", key, [step].pack("Q>"))
      at = mac.getbyte(19) & 15
      n = ((mac.getbyte(at) & 127) << 24) | (mac.getbyte(at + 1) << 16) | (mac.getbyte(at + 2) << 8) | mac.getbyte(at + 3)
      format("%06d", n % 1_000_000)
    end

    # Base32 to bytes, skipping what is not a base32 letter, as auth.ts reads a secret.
    def self.unbase32(text)
      bits = 0
      value = 0
      out = String.new(encoding: Encoding::BINARY)
      Runlight::Js.upper(text.sub(/=+\z/, "")).each_char do |c|
        i = BASE32.index(c)
        next if i.nil?

        value = ((value << 5) | i) & 0xffff
        bits += 5
        if bits >= 8
          out << ((value >> (bits - 8)) & 255).chr
          bits -= 8
        end
      end
      out
    end

    # Clears ENV_NAMES from the environment, returning what was there to put back.
    def self.clear_env
      ENV_NAMES.to_h { |name| [name, ENV.delete(name)] }
    end

    def self.restore_env(saved)
      saved.each do |name, value|
        value.nil? ? ENV.delete(name) : ENV[name] = value
      end
    end

    # PHP's empty(), as the PHP runner reads options: nil, false, 0, "", "0", [], and {} are empty.
    def self.filled?(value)
      !(value.nil? || value == false || value == 0 || value == "" || value == "0" || value == [] || value == {})
    end

    # A JSON value copied, the shape options take.
    def self.plain(value)
      Runlight::Json.decode(Runlight::Json.encode(value))
    end

    private_class_method :unbase32, :plain

    private

    def steps(scenario, make_target, store, fetcher, keep_going)
      @now = Integer(scenario["start"])
      runlight_options = (store.nil? ? {} : { "store" => store })
                         .merge(self.class.runlight_options(scenario))
                         .merge("now" => -> { @now }, "fetcher" => fetcher)
      target = make_target.call(runlight_options, self.class.routes_options(scenario))
      kept = {}
      jars = {}
      scenario["steps"].each_with_index.map do |step, i|
        play_step(step, target, fetcher, kept, jars)
      rescue StandardError, ScriptError => e
        if keep_going
          fetcher.take
          { "raised" => raised(e) }
        else
          error = RuntimeError.new("#{scenario["name"]}: step #{i + 1}, #{step["method"]} #{step["path"]}: #{e.message}")
          error.set_backtrace(e.backtrace)
          raise error
        end
      end
    end

    # An error as one line: its class, its message's first line, and the first place in lib it came from.
    def raised(error)
      lib = File.expand_path("../../lib/", __dir__)
      where = (error.backtrace || []).find { |line| line.start_with?(lib) } || error.backtrace&.first
      where = where&.delete_prefix(File.expand_path("../..", __dir__) + "/")
      "#{error.class}: #{error.message.lines.first.to_s.strip}#{where ? " (#{where})" : ""}"
    end

    def play_step(step, target, fetcher, kept, jars)
      @now += Integer(step["advance"] || 0)
      headers = {}
      (step["headers"] || {}).each { |k, v| headers[k.to_s.downcase] = fill_totp(Runlight::Js.string(v), kept) }
      body = nil
      if !step["form"].nil?
        fields = {}
        fill_deep(step["form"], kept).each { |name, value| fields[name.to_s] = Runlight::Js.string(value) }
        body = Runlight::Http::SearchParams.new(fields).to_s
        headers["content-type"] ||= "application/x-www-form-urlencoded"
      elsif step.key?("body")
        body = step["body"].is_a?(String) ? fill_totp(step["body"], kept) : Runlight::Json.encode(fill_deep(step["body"], kept))
      end
      # JavaScript's Request gives a string body this type when none is named, and the core may read it.
      headers["content-type"] ||= TEXT_BODY_TYPE unless body.nil?
      jar_name = step.key?("jar") && !step["jar"].nil? ? step["jar"] : "main"
      jar = jar_name == false ? nil : (jars[jar_name.to_s] ||= {})
      if !jar.nil? && !jar.empty? && !headers.key?("cookie")
        headers["cookie"] = jar.map { |k, v| "#{k}=#{v}" }.join("; ")
      end
      to = step["to"] || "routes"
      prefix = to == "routes" && !self.class.filled?(step["absolute"]) ? "/runlight" : ""
      raw = "https://#{step["host"] || "example.com"}#{prefix}#{fill_totp(step["path"].to_s, kept)}"
      # request.url is the parsed URL, as `new Request(url)` gives it.
      url = Runlight::Http::Url.parse(raw)&.href || raw
      request = Runlight::Http::Request.new(url, method: step["method"].to_s, headers: headers, body: body || "",
                                                 remote_address: "")
      fetcher.take
      answer =
        case to
        when "links" then target.links(request)
        when "linkDomain" then target.link_domain(request)
        else target.handle(request)
        end
      # Work the request started after answering (retention) finishes before the next one, as it would between
      # real requests.
      target.idle
      sent_out = fetcher.take
      outbound = sent_out.map { |f| Normalizer.normalize(f["seen"]) }
      if answer.nil?
        out = { "pass" => true }
        out["fetched"] = outbound unless outbound.empty?
        return out
      end
      answer(step, answer, sent_out, outbound, kept, jar)
    end

    def answer(step, answer, sent_out, outbound, kept, jar)
      bytes = answer.text
      text = Text.utf8(bytes)
      type = Runlight::Js.trim((answer.headers.get("content-type") || "").split(";", -1).first.to_s)
      parsed = nil
      has_parsed = false
      if type != "application/zip" && text != ""
        begin
          parsed = Runlight::Json.decode(text)
          has_parsed = true
        rescue Runlight::Json::ParseError, EncodingError
          nil
        end
      end
      (step["capture"] || {}).each do |name, spec|
        kept[name.to_s] = self.class.capture(spec.to_s, answer, text, has_parsed ? parsed : nil, sent_out)
      end
      unless jar.nil?
        answer.headers.get_set_cookie.each do |cookie|
          attributes = cookie.split(";", -1)
          pair = attributes.shift || ""
          at = pair.index("=")
          # As pair.slice(0, pair.indexOf("=")): with no "=", indexOf is -1, and the last character is cut.
          name = Runlight::Js.trim(at.nil? ? pair[0...-1].to_s : pair[0, at])
          value = Runlight::Js.trim(at.nil? ? pair : pair[(at + 1)..])
          clears = attributes.any? { |a| a.match?(/\A[#{Runlight::Js::SPACE}]*max-age=0[#{Runlight::Js::SPACE}]*\z/io) }
          if value.empty? || clears
            jar.delete(name)
          else
            jar[name] = value
          end
        end
      end
      sent = {}
      Normalizer::HEADERS.each do |name|
        if name == "set-cookie"
          cookies = answer.headers.get_set_cookie
          sent[name] = cookies.map { |c| Normalizer.cookie_shape(c) } unless cookies.empty?
          next
        end
        value = answer.headers.get(name)
        next if value.nil? || value.empty?

        sent[name] = name == "content-type" ? Runlight::Js.trim(value.split(";", -1).first.to_s) : Normalizer.normalize(value)
      end
      out = { "status" => answer.status }
      out["headers"] = sent unless sent.empty?
      out["body"] = Normalizer.normalize(parsed) if has_parsed
      out["text"] = Normalizer.normalize(text) if !has_parsed && ["text/plain", "text/csv"].include?(type)
      if type == "application/zip"
        out["files"] = Zip.unzip(bytes).map { |f| { "name" => f["name"], "text" => Normalizer.normalize(f["text"]) } }
      end
      out["found"] = step["look"].map { |s| text.include?(Runlight::Js.string(s)) } unless step["look"].nil?
      out["fetched"] = outbound unless outbound.empty?
      out
    end

    # {{totp:name}} as the six-digit code for the captured secret at the step's clock, then {{name}}.
    def fill_totp(text, kept)
      out = text.dup
      text.scan(/\{\{totp:(\w+)\}\}/) do |(name)|
        whole = "{{totp:#{name}}}"
        at = out.index(whole)
        out[at, whole.length] = self.class.totp(kept[name] || "", @now.div(30_000)) unless at.nil?
      end
      fill(out, kept)
    end

    # {{name}} as the value captured earlier, empty when nothing was.
    def fill(text, kept)
      text.gsub(/\{\{(\w+)\}\}/) { kept[Regexp.last_match(1)] || "" }
    end

    def fill_deep(value, kept)
      case value
      when String then fill_totp(value, kept)
      when Array then value.map { |v| fill_deep(v, kept) }
      when Hash then value.transform_values { |v| fill_deep(v, kept) }
      else value
      end
    end
  end
end
