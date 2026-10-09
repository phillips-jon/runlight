# frozen_string_literal: true

require "fileutils"
require "openssl"
require "tmpdir"

module Runlight
  # A site's icon, for the dashboard header: the best icon its home page
  # links to, or /favicon.ico. Fetched from the site's own configured origin
  # (never from request input), cached for a day.
  #
  # The cache lives in this process and in one small file per origin in the
  # system's temporary folder, so every process of an app server shares it.
  # An icon is a Hash {"body" => bytes, "type" => media type}.
  module Icon
    TIMEOUT_MS = 4000
    MAX_BYTES = 256 * 1024
    DAY = 86_400_000
    # A few hundred sites at most; past that the oldest go, so the cache cannot grow without end.
    CACHE_SIZE = 500
    # A <link> tag, matched on bytes so case folding stays ASCII, as JavaScript's /i does.
    LINK = /<link(?![A-Za-z0-9_])[^>]*>/in
    private_constant :TIMEOUT_MS, :MAX_BYTES, :DAY, :CACHE_SIZE, :LINK

    # Origin to {"at" => ms, "icon" => icon or nil}.
    @cache = {}
    @lock = Mutex.new

    module_function

    # A tag's attributes, read one after another so a name inside another (data-rel) or inside a value
    # (title="rel=icon") is never taken for one. The first of a repeated name counts, as in a browser. \s is
    # JavaScript's white space, as in the TypeScript's pattern.
    ATTRIBUTE = /([^#{Js::SPACE}"'>\/=]+)(?:[#{Js::SPACE}]*=[#{Js::SPACE}]*(?:"([^"]*)"|'([^']*)'|([^#{Js::SPACE}>]+)))?/
    private_constant :ATTRIBUTE

    def attrs(tag)
      out = {}
      tag["<link".length..].scan(ATTRIBUTE) do |name, double, single, bare|
        name = Js.lower(name)
        out[name] = Js.trim(double || single || bare || "") unless out.key?(name)
      end
      out
    end

    # Icon URLs a page links to, best first: apple-touch-icon, then SVG and PNG icons, then any icon.
    def icon_links(html, base)
      found = []
      Js.scrub(html).b.scan(LINK).each do |bytes|
        tag = bytes.dup.force_encoding(Encoding::UTF_8)
        attributes = attrs(tag)
        rel = Js.lower(attributes["rel"] || "").split(/[#{Js::SPACE}]+/)
        href = attributes["href"] || ""
        next if href.empty? || !(rel.include?("icon") || rel.include?("apple-touch-icon"))

        parsed = Http::Url.parse(href, base)
        next if parsed.nil?

        url = parsed.href
        # Only https, which is all the fetch below takes.
        next unless url.start_with?("https://")

        type = Js.lower(attributes["type"] || "")
        score = if rel.include?("apple-touch-icon") then 3
                elsif type.include?("svg") || url.end_with?(".svg") then 2
                elsif type.include?("png") || url.end_with?(".png") then 1
                else 0
                end
        found << { "url" => url, "score" => score }
      end
      # A stable sort, as Array.prototype.sort is.
      found.each_with_index.sort_by { |f, i| [-f["score"], i] }.map { |f, _| f["url"] }
    end

    # A GET of a public https address, with redirects followed only to public addresses too.
    def get(url, fetcher, read)
      init = { "timeoutMs" => TIMEOUT_MS, "redirects" => 3, "headers" => { "user-agent" => "Runlight (+https://runlight.sh)" } }
      Safefetch.public_fetch(url, init.merge(read), fetcher)
    rescue StandardError
      nil
    end

    def image(url, fetcher)
      # An image must arrive whole, so one longer than the cap is no use.
      response = get(url, fetcher, { "maxBytes" => MAX_BYTES })
      return nil if response.nil? || !response.ok?

      type = Js.lower(Js.trim((response.headers.get("content-type") || "").split(";", 2).first.to_s))
      return nil unless type.start_with?("image/")
      return nil if Js.number(response.headers.get("content-length")) > MAX_BYTES

      body = response.text
      return nil if body.empty? || body.bytesize > MAX_BYTES

      { "body" => body.b, "type" => type }
    end

    # The site's icon, or nil when it has none that can be fetched.
    # now: milliseconds, the clock when nil; dir: where the file cache goes, the system's temporary folder when nil.
    def fetch_icon(origin, now = nil, fetcher = nil, dir = nil)
      now ||= Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
      cached = cached(origin, dir)
      return cached["icon"] if !cached.nil? && now - cached["at"] < (cached["icon"].nil? ? DAY / 24 : DAY)

      # TS shares one lookup among dashboards opening at once; here each looks for itself.
      icon = look_up(origin, fetcher)
      store(origin, { "at" => now, "icon" => icon }, dir)
      icon
    end

    def look_up(origin, fetcher)
      icon = nil
      # The head is all that is needed, so a huge page is not read to the end.
      page = get("#{origin}/", fetcher, { "maxBytes" => 200_000, "truncate" => true })
      if !page.nil? && page.ok? && (page.headers.get("content-type") || "").include?("html")
        html = Body.utf8(page.text)
        # A Response from the fetcher has no url of its own, as the one Node's https module gives, so links
        # resolve against the origin.
        icon_links(html, origin).first(4).each do |url|
          icon = image(url, fetcher)
          break unless icon.nil?
        end
      end
      icon || image("#{origin}/favicon.ico", fetcher)
    end

    def cached(origin, dir)
      hit = @lock.synchronize { @cache[origin] }
      return hit unless hit.nil?

      file = file(origin, dir)
      return nil if file.nil?

      saved = Json.try_decode(File.read(file))
      return nil if !saved.is_a?(Hash) || !saved.key?("at")

      body = saved["body"].is_a?(String) ? saved["body"].unpack1("m0") : nil
      icon = body.nil? || !saved.key?("type") ? nil : { "body" => body, "type" => saved["type"].to_s }
      { "at" => saved["at"].to_i, "icon" => icon }
    rescue SystemCallError, IOError, ArgumentError
      nil
    end

    def store(origin, entry, dir)
      @lock.synchronize do
        @cache.delete(origin)
        @cache[origin] = entry
        @cache.delete(@cache.keys.first) if @cache.size > CACHE_SIZE
      end
      file = file(origin, dir)
      return if file.nil?

      saved = { "at" => entry["at"] }
      saved.merge!("type" => entry["icon"]["type"], "body" => [entry["icon"]["body"]].pack("m0")) unless entry["icon"].nil?
      begin
        File.open(file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |handle|
          handle.flock(File::LOCK_EX)
          handle.write(Json.encode(saved))
        end
        # Past the cap the oldest files go.
        files = Dir.glob(File.join(File.dirname(file), "*.json"))
        if files.length > CACHE_SIZE
          files.sort_by { |f| File.exist?(f) ? File.mtime(f) : Time.at(0) }.first(files.length - CACHE_SIZE).each do |old|
            FileUtils.rm_f(old)
          end
        end
      rescue SystemCallError, IOError
        nil
      end
    end

    def file(origin, dir)
      dir = File.join(dir || Dir.tmpdir, "runlight-icons")
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.join(dir, "#{OpenSSL::Digest::SHA256.hexdigest(origin)}.json")
    rescue SystemCallError
      nil
    end

    private_class_method :attrs, :get, :image, :look_up, :cached, :store, :file
  end
end
