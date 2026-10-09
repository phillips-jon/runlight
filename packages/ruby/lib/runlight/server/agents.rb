# frozen_string_literal: true

require "openssl"

module Runlight
  module Server
    # runlight agents: counts AI agents on a site that has only the script
    # tag, by reading its web server's access log. Agents do not run JavaScript, so
    # the tracker never sees them; the server that answered them did.
    #
    # It reads nginx and Apache's combined format and Caddy's JSON lines, keeps
    # successful GETs from known AI agents, and sends them in batches to a
    # Runlight's /api/observe with the site's observe key. Nothing else in the log
    # leaves the machine. With follow it keeps reading as the log grows and
    # carries on after the log is rotated. Without it, it reads what is new and
    # stops, for cron. In both modes the state file remembers how far it read, so the
    # next run, or a restarted follow, carries on from there.
    #
    # The port of the Node server's agents.ts. A fetch is a Hash of url, userAgent, and at (epoch milliseconds).
    module Agents
      MONTHS = { "Jan" => 0, "Feb" => 1, "Mar" => 2, "Apr" => 3, "May" => 4, "Jun" => 5, "Jul" => 6, "Aug" => 7,
                 "Sep" => 8, "Oct" => 9, "Nov" => 10, "Dec" => 11 }.freeze

      # JavaScript's \S, which also leaves out Unicode spaces.
      S = "[^#{Js::SPACE}]"

      # host? ip - user [time] "METHOD /path HTTP/x" status bytes "referrer" "user agent"
      COMBINED = /\A(?:(#{S}+) )?#{S}+ #{S}+ #{S}+ \[([^\]]+)\] "(#{S}+) (#{S}+)[^"]*" ([0-9]{3}) #{S}+ "(?:[^"\\]|\\[^\n\r  ])*" "((?:[^"\\]|\\[^\n\r  ])*)"/

      # A request line and status, in a line that might be a combined log line without its host.
      REQUEST = %r{"#{S}+ /#{S}* [^"]*" [0-9]{3}}

      # The most fetches /api/observe takes at once.
      BATCH = 500

      # The most of a log read at once, so a log of any size fits in memory a piece at a time.
      CHUNK = 32 * 1024 * 1024

      # How many bytes at the start of a log identify it.
      HEAD = 256

      private_constant :MONTHS, :S, :COMBINED, :REQUEST, :CHUNK, :HEAD

      module_function

      # A request target as a page on the site. Absolute targets ("GET http://other/x", a proxy
      # request) name somewhere else and are skipped. The target is set as the path and query of the
      # site's own address, never parsed as a URL, so "//x" and "/\x" stay paths on the site.
      def page_url(target, base)
        return nil unless target.start_with?("/")

        url = Http::Url.parse(base)
        return nil if url.nil?

        query = target.index("?")
        url.set_pathname("/#{(query.nil? ? target : target[0, query]).sub(%r{\A/+}, "")}")
        url.set_search(query.nil? ? "" : target[query..])
        url.hash = ""
        url.href
      end

      # "07/Oct/2026:13:55:36 -0400" as epoch milliseconds, or NaN.
      def log_time(value)
        m = value.match(%r{\A(\d{2})/(\w{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})\z})
        return Float::NAN if m.nil? || !MONTHS.key?(m[2])

        # Date.UTC reads years 0 to 99 as 1900 to 1999, and lets days and hours run on past their end.
        year = m[3].to_i
        year += year <= 99 ? 1900 : 0
        days = days_from_civil(year, MONTHS[m[2]] + 1) + m[1].to_i - 1
        local = (((((days * 24) + m[4].to_i) * 60) + m[5].to_i) * 60 + m[6].to_i) * 1000
        offset = ((m[8].to_i * 60) + m[9].to_i) * 60_000 * (m[7] == "-" ? -1 : 1)
        local - offset
      end

      # Days from 1970-01-01 to the first of this month.
      def days_from_civil(year, month)
        y = month <= 2 ? year - 1 : year
        era = (y >= 0 ? y : y - 399).quo(400).truncate
        yoe = y - (era * 400)
        doy = ((153 * (month + (month > 2 ? -3 : 9))) + 2) / 5
        doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy
        (era * 146_097) + doe - 719_468
      end

      # value?.[key], for a value that may be null or undefined.
      def at(value, key)
        value.nil? || value.equal?(UNDEFINED) ? UNDEFINED : Js.get(value, key)
      end

      # a ?? b
      def either(value, otherwise)
        value.nil? || value.equal?(UNDEFINED) ? otherwise : value
      end

      # A whole float as an Integer, as JavaScript makes no difference between them.
      def whole(n)
        n.is_a?(Float) && n.finite? && n.floor == n && n.abs < 9.0e15 ? n.to_i : n
      end

      # One log line as a page fetch, or nil. `site` is the address pages live at
      # (https://example.com), for formats that do not record the host.
      def parse_line(line, site = nil)
        text = Js.trim(line)
        return nil if text.empty?

        if text.start_with?("{")
          # Caddy: {"ts": 1696..., "request": {"method", "host", "uri", "headers": {"User-Agent": [...]}}, "status": 200}
          begin
            entry = Json.decode(text)
            request = at(entry, "request")
            uri = at(request, "uri")
            method = at(request, "method")
            return nil if !Js.truthy?(uri) || !Js.truthy?(method)

            host = at(request, "host")
            host = if Js.truthy?(host)
                     scheme = if Js.truthy?(at(request, "tls")) then "https"
                              elsif !site.nil? && site.start_with?("http://") then "http"
                              else "https"
                              end
                     "#{scheme}://#{Js.string(host)}"
                   else
                     site
                   end
            return nil if host.nil? || host == ""

            headers = at(request, "headers")
            ua = either(at(at(headers, "User-Agent"), 0), either(at(at(headers, "user-agent"), 0), ""))
            ts = at(entry, "ts")
            at_ms = if ts.is_a?(Integer) || ts.is_a?(Float)
                      whole(ts * 1000)
                    else
                      Importers::Client.parse_date(Js.string(either(ts, "")))
                    end
            # A target that is not text cannot be a page, as startsWith throws on it in TypeScript.
            url = uri.is_a?(String) ? page_url(uri, host) : nil
            return nil if url.nil?

            return { "method" => method, "url" => url, "status" => Js.number(either(at(entry, "status"), 0)),
                     "userAgent" => Js.string(ua), "at" => at_ms }
          rescue Json::ParseError, TypeError
            return nil
          end
        end
        m = text.match(COMBINED)
        return nil if m.nil?

        # A vhost column first ("example.com:443 1.2.3.4 - - [...]") names the host; otherwise site does.
        first = m[1].to_s
        vhost = if first != "" && first.match?(/[a-z]/i) && !first.match?(/\A[0-9.:]+\z/)
                  first.sub(/:[0-9]+\z/, "")
                end
        base = vhost.nil? ? site : "https://#{vhost}"
        return nil if base.nil? || base == ""

        url = page_url(m[4], base)
        return nil if url.nil?

        { "method" => m[3], "url" => url, "status" => m[5].to_i, "userAgent" => m[6].gsub('\\"', '"'),
          "at" => log_time(m[2]) }
      end

      # The lines worth sending: GETs that succeeded, from known AI agents. now gives epoch milliseconds, for a
      # line whose time cannot be read.
      def agent_fetch(line, site = nil, now = nil)
        hit = parse_line(line, site)
        return nil if hit.nil? || hit["method"] != "GET" || hit["status"] < 200 || hit["status"] >= 400 ||
                      Ua.ai_agent(hit["userAgent"]).nil?

        at = hit["at"]
        finite = !at.is_a?(Float) || at.finite?
        { "url" => hit["url"], "userAgent" => hit["userAgent"], "at" => finite ? at : (now || method(:clock)).call }
      end

      def clock
        Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
      end

      # Sends one batch of fetches to /api/observe and returns how many Runlight kept.
      def send_batch(options, fetcher, fetches)
        begin
          answer = fetcher.fetch("#{options["to"].to_s.sub(%r{/+\z}, "")}/api/observe", {
                                   "method" => "POST",
                                   "headers" => { "authorization" => "Bearer #{options["key"]}",
                                                  "content-type" => "application/json" },
                                   "body" => Json.encode({ "fetches" => fetches }),
                                   "timeoutMs" => 30_000,
                                 })
        rescue StandardError => e
          raise SendError, e.message
        end
        if answer.status == 401
          raise SendError, "Runlight refused the key. Use the site's key from Settings, Install, Key for CMS plugins."
        end
        raise SendError, "Runlight answered #{answer.status}: #{Js.slice(Js.scrub(answer.text), 0, 200)}" unless answer.ok?

        body = Json.try_decode(answer.text)
        recorded = body.is_a?(Hash) ? body["recorded"] : nil
        recorded.is_a?(Integer) || recorded.is_a?(Float) ? recorded : 0
      end

      # Opens a file for reading, or raises with the reason, as Node's openSync does.
      def open_log(file)
        File.open(file, "rb")
      rescue SystemCallError => e
        raise RuntimeError, reason(e, "Could not open #{file}")
      end

      # A system error's text, without the path Ruby adds after it.
      def reason(error, otherwise)
        text = error.message.sub(/ @ \w+ - .*\z/m, "").sub(/ - .*\z/m, "")
        text.empty? ? otherwise : text
      end

      def stat(file)
        found = File.stat(file)
        { "ino" => found.ino, "size" => found.size }
      rescue SystemCallError => e
        raise RuntimeError, reason(e, "Could not read #{file}")
      end

      def size(fd)
        fd.stat.size
      rescue SystemCallError, IOError
        raise RuntimeError, "Could not read the log"
      end

      # Up to `length` bytes from `offset`.
      def read_at(fd, offset, length)
        return "".b if length <= 0

        begin
          fd.seek(offset)
        rescue SystemCallError, IOError
          raise RuntimeError, "Could not read the log"
        end
        buffer = "".b
        while buffer.bytesize < length
          begin
            part = fd.read(length - buffer.bytesize)
          rescue SystemCallError, IOError => e
            raise RuntimeError, reason(e, "Could not read the log")
          end
          break if part.nil? || part.empty?

          buffer << part
        end
        buffer
      end

      # A fingerprint of the log's first bytes. A log rotated by copying and truncating keeps its inode,
      # so a different start is how a new log shows itself. An open file (in follow mode) is read as it is,
      # even once it is renamed.
      def head_of(file, length = HEAD)
        fd = file.is_a?(String) ? open_log(file) : file
        begin
          buffer = read_at(fd, 0, [length, size(fd)].min)
          { "head" => OpenSSL::Digest::SHA256.hexdigest(buffer), "length" => buffer.bytesize }
        ensure
          fd.close if file.is_a?(String)
        end
      end

      # Whether the log at this inode still starts the way it did, so a saved place in it still holds.
      def same_log?(file, saved, stat)
        return false if saved["ino"] != stat["ino"]
        return true if !Js.truthy?(saved["head"]) || saved["length"].nil?

        length = integer(saved["length"])
        stat["size"] >= length && head_of(file, length)["head"] == saved["head"]
      end

      # PHP's (int) of a value read from JSON.
      def integer(value)
        case value
        when Integer then value
        when Float then value.finite? ? value.to_i : 0
        when String then value.to_i
        when true then 1
        else 0
        end
      end

      # Reads whole lines from a byte offset, at most a chunk, and returns where the next read starts.
      # Offsets count bytes up to each newline byte, so a malformed character cannot shift them. `ends`
      # holds where the line after each one starts, so a place can be saved part way through a chunk.
      def read_from(file, offset)
        # A path is opened for this read; an open file (in follow mode) stays open, even once it is renamed.
        size = file.is_a?(String) ? stat(file)["size"] : size(file)
        return { "lines" => [], "ends" => [], "next" => offset, "more" => false } if size <= offset

        fd = file.is_a?(String) ? open_log(file) : file
        begin
          buffer = read_at(fd, offset, [size - offset, CHUNK].min)
          finish = buffer.rindex("\n")
          # A half-written last line waits for the next read (or, in a chunk with no newline at all, is skipped).
          if finish.nil?
            return buffer.bytesize == CHUNK ? { "lines" => [], "ends" => [], "next" => offset + buffer.bytesize, "more" => true } : { "lines" => [], "ends" => [], "next" => offset, "more" => false }
          end

          lines = []
          ends = []
          start = 0
          while start <= finish
            newline = buffer.index("\n", start)
            # Read as UTF-8 the way Node does, each malformed sequence becoming U+FFFD.
            lines << Js.scrub(buffer.byteslice(start, newline - start))
            ends << (offset + newline + 1)
            start = newline + 1
          end
          { "lines" => lines, "ends" => ends, "next" => offset + finish + 1,
            "more" => offset + buffer.bytesize < size }
        ensure
          fd.close if file.is_a?(String)
        end
      end

      # Whether a process with this id is running on this machine.
      def running?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::EPERM
        # It runs, as someone else.
        true
      rescue Errno::ESRCH, RangeError
        false
      end

      # The text of a file, or nil when it cannot be read.
      def contents(file)
        File.binread(file)
      rescue SystemCallError, IOError
        nil
      end

      # Takes the lock beside a state file, so two runs never read from the same place and send the
      # same lines twice. The lock holds the run's process id; a lock left by a process that is no longer
      # running is taken over. Returns the release.
      def lock(state)
        path = "#{state}.lock"
        mine = Process.pid.to_s
        3.times do
          fd = begin
            File.open(path, File::WRONLY | File::CREAT | File::EXCL)
          rescue SystemCallError
            nil
          end
          unless fd.nil?
            fd.write(mine)
            fd.close
            released = false
            release = lambda do
              next if released

              released = true
              File.unlink(path) if contents(path) == mine
            rescue SystemCallError
              nil
            end
            # Released on exit too, as a run that stops part way would otherwise leave its lock behind.
            at_exit { release.call }
            return release
          end
          raise RuntimeError, "Could not create #{path}" unless File.exist?(path)

          held = contents(path)
          next if held.nil?

          held = Js.trim(held)
          pid = Js.number(held)
          # A lock being written has no id in it yet, so it counts as held.
          break if held == "" || (pid.is_a?(Integer) && pid.positive? && running?(pid))

          # Stale. Moving it aside is atomic, so of two runs taking it over only one moves this lock; one
          # that finds a newer lock moved aside puts it back.
          aside = "#{path}.#{mine}"
          begin
            File.rename(path, aside)
          rescue SystemCallError
            next
          end
          if Js.trim(contents(aside).to_s) != held
            begin
              File.link(aside, path)
            rescue SystemCallError
              nil
            end
            File.unlink(aside)
            break
          end
          File.unlink(aside)
        end
        holder = Js.trim(contents(path).to_s)
        raise RuntimeError, "Another run is using #{state}#{holder == "" ? "" : " (process #{holder})"}. " \
                            "Wait for it to finish, or delete #{path} if none is running."
      end

      # Writes the state whole or not at all, so a crash part way never leaves it empty.
      def write_state(state, saved)
        temp = "#{state}.#{Process.pid}.tmp"
        begin
          File.binwrite(temp, Json.encode(saved))
          File.rename(temp, state)
        rescue SystemCallError => e
          raise RuntimeError, reason(e, "Could not write #{state}")
        end
      end

      # Reads the log and sends what AI agents fetched, returning how many fetches Runlight kept.
      #
      # Options, as the Node command's (String keys):
      # - log: the access log's path
      # - to: the Runlight to report to, as its dashboard address
      # - key: the site's observe key
      # - site: the site's address, for logs with no host in them
      # - follow: keep reading as the log grows
      # - state: where runs remember how far they read, so the next one (or a restarted follow) carries on
      # - out: a callable taking a line for what it has to say; printed by default
      # - stop: a callable that ends follow when it returns true, which otherwise runs until the process stops
      # - pollMs: how often follow looks at the log, 2 seconds by default
      # - sleep: a callable taking milliseconds that waits between looks, sleep by default
      # - fetcher: what reaches Runlight, Http::NetFetcher by default
      # - now: a callable returning epoch milliseconds, for lines whose time cannot be read
      def run(options)
        options = Options.normalize(options)
        release = options["state"] ? lock(options["state"]) : -> {}
        begin
          read_log(options)
        ensure
          release.call
        end
      end

      def read_log(options)
        out = options["out"] || ->(line) { $stdout.write("#{line}\n") }
        fetcher = options["fetcher"] || Http::NetFetcher.new
        now = options["now"] || method(:clock)
        site = options["site"].nil? || options["site"] == "" ? nil : options["site"].to_s
        state = options["state"].nil? || options["state"] == "" ? nil : options["state"].to_s
        log = options["log"].to_s
        raise RuntimeError, "No log at #{log}" unless File.exist?(log)

        total = 0
        warned = false
        # Sends the agent fetches among lines read, a batch at a time, calling `done` with where the next
        # unsent line starts after each batch, so a failure part way sends none of the earlier batches again.
        handle = lambda do |read, done|
          lines = read["lines"]
          ends = read["ends"]
          # Lines with no host and no site cannot be placed on a site; say so once rather than skip them silently.
          if site.nil? && !warned
            lines.each do |line|
              next unless !Js.trim(line).start_with?("{") && line.match?(REQUEST) && parse_line(line).nil?

              warned = true
              out.call("Some lines have no host in them. Add --site https://your-site.example so they can be counted.")
              break
            end
          end
          kept = 0
          batch = []
          count = lines.length
          lines.each_with_index do |line, i|
            found = agent_fetch(line, site, now)
            batch << found unless found.nil?
            next unless batch.length == BATCH || (i == count - 1 && !batch.empty?)

            recorded = send_batch(options, fetcher, batch)
            kept += recorded
            total += recorded
            batch = []
            done.call(ends[i])
          end
          kept
        end
        # The place to save: the file being read, by its inode and its own start, and how far into it.
        save = lambda do |ino, offset, head|
          unless state.nil?
            write_state(state, { "ino" => ino, "offset" => offset, "head" => head["head"], "length" => head["length"] })
          end
        end
        # Where the last run stopped, or nil with a word about it when the state file cannot be read.
        read_state = lambda do
          return nil if state.nil? || !File.exist?(state)

          saved = Json.try_decode(contents(state).to_s)
          ino = saved.is_a?(Hash) ? saved["ino"] : nil
          offset = saved.is_a?(Hash) ? saved["offset"] : nil
          if (ino.is_a?(Integer) || ino.is_a?(Float)) && (offset.is_a?(Integer) || offset.is_a?(Float))
            found = { "ino" => whole(ino), "offset" => whole(offset) }
            found["head"] = saved["head"] if saved.key?("head")
            found["length"] = saved["length"] if saved.key?("length")
            return found
          end
          out.call("Could not read #{state}, so this run starts as if it were the first.")
          nil
        end

        unless Js.truthy?(options["follow"])
          # Where the last run stopped, unless the log was rotated since (a new file, a shorter one, or a new start).
          saved = read_state.call
          stat = stat(log)
          offset = !saved.nil? && saved["offset"] <= stat["size"] && same_log?(log, saved, stat) ? saved["offset"].to_i : 0
          count = 0
          # A batch at a time, saving the place after each, so a failure part way resends nothing already sent.
          loop do
            read = read_from(log, offset)
            handle.call(read, ->(at) { save.call(stat["ino"], at, head_of(log)) })
            count += read["lines"].length
            offset = read["next"]
            save.call(stat["ino"], offset, head_of(log))
            break unless read["more"]
          end
          out.call("Sent #{Js.string(total)} AI agent fetches from #{count} new lines.")
          return total
        end

        # Follow: start where the state says, else at the end like tail -F. A log that was rotated since the
        # state was saved is all new, so it is read from its start.
        stop = options["stop"] || -> { false }
        sleeper = options["sleep"] || ->(ms) { sleep(ms / 1000.0) }
        poll_ms = (options["pollMs"] || 2000).to_i
        resumed = read_state.call
        first = stat(log)
        ino = first["ino"]
        offset = if resumed.nil?
                   first["size"]
                 else
                   resumed["offset"] <= first["size"] && same_log?(log, resumed, first) ? resumed["offset"].to_i : 0
                 end
        out.call("Following #{log}. AI agent fetches go to #{options["to"]} as they happen.")
        # The log stays open, so when it is renamed in a rotation, what was written to it before the
        # switch is still read to the end before the new log starts. Its fingerprint is taken from the
        # open file too, so a place saved while finishing an old log names that log, never the new one.
        fd = open_log(log)
        known = head_of(fd)
        # The same trouble every two seconds is said once, until something changes.
        trouble = ""
        until stop.call
          sleeper.call(poll_ms)
          begin
            stat = File.exist?(log) ? stat(log) : nil
            renamed = stat.nil? || stat["ino"] != ino
            # Copied and truncated in place: the same file, shorter or with a new start.
            if !renamed && (stat["size"] < offset || !same_log?(log, { "ino" => ino }.merge(known), stat))
              offset = 0
            end
            read = read_from(fd, offset)
            sent = handle.call(read, lambda do |at|
              offset = at
              save.call(ino, offset, known)
            end)
            # Only past lines that were sent, so a failed send is tried again next time.
            offset = read["next"]
            save.call(ino, offset, known)
            out.call("Sent #{Js.string(sent)} AI agent fetches.") if Js.truthy?(sent)
            if renamed && !stat.nil? && !read["more"]
              # The old log is finished; the new one is read from its start.
              following = open_log(log)
              fd.close
              fd = following
              ino = stat["ino"]
              offset = 0
            end
            # The start grows until it is HEAD bytes long, so the fingerprint is taken again each time.
            known = head_of(fd)
            trouble = ""
          rescue StandardError => e
            said = if e.is_a?(SendError)
                     "Could not send, trying again shortly: #{e.message}"
                   else
                     "Could not read #{log}, trying again shortly: #{e.message}"
                   end
            out.call(said) if said != trouble
            trouble = said
          end
        end
        fd.close
        total
      end

      private_class_method :page_url, :log_time, :days_from_civil, :at, :either, :whole, :clock, :send_batch,
                           :open_log, :reason, :stat, :size, :read_at, :head_of, :same_log?, :integer, :read_from,
                           :running?, :contents, :lock, :write_state, :read_log
    end
  end
end
