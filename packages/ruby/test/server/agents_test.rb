# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "rbconfig"
require "stringio"
require "tmpdir"

# The port of the Node server's agents.test.ts: the access log reader that counts AI agents.
class ServerAgentsTest < Minitest::Test
  Agents = Runlight::Server::Agents
  Json = Runlight::Json
  Response = Runlight::Http::Response

  GPTBOT = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)"
  CLAUDE = "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)"
  CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

  QUIET = ->(_line) {}

  def setup
    @dir = Dir.mktmpdir("runlight-agents-")
  end

  def teardown
    FileUtils.chmod(0o644, "#{@dir}/access.log") if File.file?("#{@dir}/access.log")
    FileUtils.rm_rf(@dir)
    super
  end

  def self.line(path, ua, status = 200, method = "GET", time = "07/Oct/2026:13:55:36 -0400", vhost = "")
    "#{vhost == "" ? "" : "#{vhost} "}203.0.113.9 - - [#{time}] \"#{method} #{path} HTTP/1.1\" #{status} 5120 \"-\" \"#{ua}\""
  end

  def line(...)
    self.class.line(...)
  end

  def utc(y, m, d, h = 0, i = 0, s = 0)
    Time.utc(y, m, d, h, i, s).to_i * 1000
  end

  # The files in the test's folder.
  def files
    Dir.children(@dir).sort
  end

  # A Runlight that takes reports for example.com with the key rlo_site, and a fetcher that reaches its routes.
  def runlight
    now = utc(2026, 10, 7, 18)
    rl = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "site" => { "hostnames" => ["example.com"] },
                              "now" => -> { now } })
    rl.init
    rl.store.set_setting("observe-key:default", "rlo_site")
    routes = rl.routes({ "token" => "owner" })
    fetcher = FakeFetcher.new do |url, init|
      routes.handle(Runlight::Http::Request.new(url, method: init["method"] || "GET", headers: init["headers"] || {},
                                                     body: init["body"].to_s))
    end
    [rl, fetcher]
  end

  # A fetcher like a small server that keeps each batch, answering with how many it took. answer gives an
  # answer of its own for a post, from its number and size.
  def counter(answer = nil)
    @stored = 0
    @posts = 0
    FakeFetcher.new do |_url, init|
      @posts += 1
      n = Json.decode(init["body"].to_s)["fetches"].length
      own = answer&.call(@posts, n)
      next own unless own.nil?

      @stored += n
      Response.json({ "recorded" => n })
    end
  end

  def run_agents(options)
    Agents.run({ "out" => QUIET }.merge(options))
  end

  def test_log_lines_nginx_and_apache_combined_a_vhost_column_and_caddys_json
    assert_equal({ "method" => "GET", "url" => "https://example.com/blog/post?x=1", "status" => 200, "userAgent" => GPTBOT,
                   "at" => utc(2026, 10, 7, 17, 55, 36) },
                 Agents.parse_line(line("/blog/post?x=1", GPTBOT), "https://example.com"))
    assert_nil Agents.parse_line(line("/", GPTBOT)), "with no host anywhere there is no page to name"
    assert_equal "https://blog.example.com/",
                 Agents.parse_line(line("/", GPTBOT, 200, "GET", "07/Oct/2026:13:55:36 -0400", "blog.example.com:443"))["url"]
    caddy = Json.encode({ "ts" => 1_791_399_336.5, "status" => 200,
                          "request" => { "method" => "GET", "host" => "example.com", "uri" => "/docs/", "tls" => {},
                                         "headers" => { "User-Agent" => [CLAUDE] } } })
    assert_equal({ "method" => "GET", "url" => "https://example.com/docs/", "status" => 200, "userAgent" => CLAUDE,
                   "at" => 1_791_399_336_500 }, Agents.parse_line(caddy))
    assert_nil Agents.parse_line("not a log line")
    # A target is a path and query on the site, never read as an address: a backslash cannot name another host.
    assert_equal "https://example.com//evil.example/x?y=1",
                 Agents.parse_line(line("/\\evil.example/x?y=1", GPTBOT), "https://example.com")["url"]
    assert_equal "https://example.com/evil.example/x",
                 Agents.parse_line(line("//evil.example/x", GPTBOT), "https://example.com")["url"]

    # Only successful GETs from AI agents are worth sending.
    refute_nil Agents.agent_fetch(line("/", GPTBOT), "https://example.com")
    assert_nil Agents.agent_fetch(line("/", CHROME), "https://example.com"), "people are the tracker's job"
    assert_nil Agents.agent_fetch(line("/", GPTBOT, 404), "https://example.com")
    assert_nil Agents.agent_fetch(line("/", GPTBOT, 200, "POST"), "https://example.com")
  end

  def test_lines_are_read_as_the_node_command_reads_them
    fixture = Fixtures.load("agents")
    now = -> { fixture["now"] }
    fixture["cases"].each do |c|
      parsed = Agents.parse_line(c["line"], c["site"])
      parsed["at"] = "NaN" if !parsed.nil? && parsed["at"].is_a?(Float) && parsed["at"].nan?
      if c["parsed"].nil?
        assert_nil parsed, Fixtures.label(c)
      else
        assert_equal c["parsed"], parsed, Fixtures.label(c)
      end
      fetched = Agents.agent_fetch(c["line"], c["site"], now)
      if c["fetched"].nil?
        assert_nil fetched, Fixtures.label(c)
      else
        assert_equal c["fetched"], fetched, Fixtures.label(c)
      end
    end
  end

  def test_a_log_is_read_once_carries_on_where_it_stopped_and_starts_over_after_rotation
    rl, fetcher = runlight
    to = "http://127.0.0.1:9/runlight"
    log = "#{@dir}/access.log"
    state = "#{@dir}/state.json"
    fetches = -> { rl.store.db.all("SELECT path, name, ts FROM rl_events WHERE kind = 'fetch' ORDER BY ts, path") }
    run = -> { run_agents({ "log" => log, "to" => to, "key" => "rlo_site", "site" => "https://example.com", "state" => state, "fetcher" => fetcher }) }

    File.write(log, [line("/a", GPTBOT), line("/b", CHROME), line("/c", CLAUDE, 200, "GET", "07/Oct/2026:13:56:00 -0400"),
                     line("/style.css", GPTBOT), ""].join("\n"))
    assert_equal 2, run.call, "two pages count; the stylesheet and the person do not"
    first = fetches.call
    assert_equal [["/a", "GPTBot"], ["/c", "ClaudeBot"]], first.map { |f| [f["path"], f["name"]] },
                 "Runlight keeps pages, not their assets"
    assert_equal utc(2026, 10, 7, 17, 55, 36), Integer(first[0]["ts"]), "counted when the page was served"
    assert_equal "Bearer rlo_site", fetcher.requests[0]["headers"]["authorization"]
    assert_equal "http://127.0.0.1:9/runlight/api/observe", fetcher.requests[0]["url"]

    assert_equal 0, run.call, "nothing new, nothing sent"
    File.write(log, "#{line("/d", GPTBOT)}\n", mode: "a")
    assert_equal 1, run.call

    File.rename(log, "#{log}.1")
    File.write(log, "#{line("/e", CLAUDE)}\n")
    assert_equal 1, run.call, "a rotated log is read from the top"
    assert_equal ["/a", "/c", "/d", "/e"], fetches.call.map { |f| f["path"] }.sort
    File.unlink("#{log}.1")

    error = assert_raises(RuntimeError, "a wrong key is refused") do
      run_agents({ "log" => log, "to" => to, "key" => "rlo_wrong", "site" => "https://example.com", "fetcher" => fetcher })
    end
    assert_includes error.message, "refused the key"

    # Lines for another host, a // path, an absolute target, an old line, and a bad byte: none stops the rest.
    before = fetches.call.length
    File.binwrite(log, [
      "#{line("/f", GPTBOT, 200, "GET", "07/Oct/2026:13:57:00 -0400", "other.example:443")}\n",
      "#{line("//g", GPTBOT)}\n",
      "#{line("http://evil.example/h", GPTBOT)}\n",
      "#{line("/old", GPTBOT, 200, "GET", "01/Sep/2026:10:00:00 -0400")}\n",
      "\xff\xfe\n".b,
      "#{line("/i", CLAUDE)}\n",
    ].map(&:b).join)
    assert_equal 2, run.call, "/g and /i count; the other host, the absolute target, and the old line do not"
    paths = fetches.call.map { |f| f["path"] }
    assert_equal before + 2, paths.length
    assert_includes paths, "/g"
    assert_includes paths, "/i"
    refute_includes paths, "/f"
    refute_includes paths, "/h"
    refute_includes paths, "/old"
    assert_equal 0, run.call, "the offset after a bad byte lands on the next line, so nothing is sent twice"

    # Rotated by copying and truncating: the same file, a new start, already longer than the old place.
    File.write(log, "#{line("/one", GPTBOT)}\n")
    assert_equal 1, run.call
    File.write(log, "#{line("/two", CLAUDE)}\n#{line("/three", GPTBOT)}\n")
    assert_equal 2, run.call, "both lines of the new log, none skipped"
  end

  def test_following_a_log_reads_what_was_written_just_before_a_rotation_then_the_new_log
    rl, fetcher = runlight
    log = "#{@dir}/access.log"
    File.write(log, "")
    polls = 0
    # Each look at the log waits first; the steps run in that wait, as another process writing the log would.
    sleeper = lambda do |_ms|
      polls += 1
      next unless polls == 2

      File.write(log, "#{line("/before", GPTBOT)}\n", mode: "a")
      # Rotated before the reader looks again: the last line is in the renamed file only.
      File.write(log, "#{line("/last-old", CLAUDE)}\n", mode: "a")
      File.rename(log, "#{log}.1")
      File.write(log, "#{line("/new", GPTBOT)}\n")
    end
    said = []
    Agents.run({ "log" => log, "to" => "http://127.0.0.1:9/runlight", "key" => "rlo_site", "site" => "https://example.com",
                 "follow" => true, "fetcher" => fetcher, "sleep" => sleeper, "stop" => -> { polls >= 6 },
                 "out" => ->(l) { said << l } })
    paths = rl.store.db.all("SELECT path FROM rl_events WHERE kind = 'fetch' ORDER BY path").map { |r| r["path"] }
    assert_equal ["/before", "/last-old", "/new"], paths
    assert_equal "Following #{log}. AI agent fetches go to http://127.0.0.1:9/runlight as they happen.", said[0]
    assert_equal ["Sent 2 AI agent fetches.", "Sent 1 AI agent fetches."], said[1..]
  end

  def test_a_failed_batch_sends_none_of_the_earlier_ones_again_and_a_bad_state_file_starts_over_with_a_word
    fail_at = 0
    fetcher = counter(->(post, _n) { post == fail_at ? Response.new("busy", status: 503) : nil })
    log = "#{@dir}/access.log"
    state = "#{@dir}/state.json"
    File.write(log, (0...1200).map { |i| "#{line("/p#{i}", GPTBOT)}\n" }.join)
    options = { "log" => log, "to" => "http://127.0.0.1:9", "key" => "k", "site" => "https://example.com", "state" => state, "fetcher" => fetcher }
    fail_at = 2
    error = assert_raises(RuntimeError, "the second batch fails") { run_agents(options) }
    assert_equal "Runlight answered 503: busy", error.message
    assert_equal 500, @stored, "the first batch went"
    run_agents(options)
    assert_equal 1200, @stored, "each line once"

    File.write(state, "{ not json")
    said = []
    @stored = 0
    Agents.run(options.merge("out" => ->(l) { said << l }))
    assert_match(/\ACould not read .*state\.json/, said[0])
    assert_equal "Sent 1200 AI agent fetches from 1200 new lines.", said[1]
    assert_equal 1200, @stored, "read from the top"
    assert_equal File.size(log), Json.decode(File.read(state))["offset"]
  end

  def test_lines_with_no_host_and_no_site_are_mentioned_once
    log = "#{@dir}/access.log"
    File.write(log, "#{line("/a", GPTBOT)}\n#{line("/b", GPTBOT)}\n")
    said = []
    sent = Agents.run({ "log" => log, "to" => "http://127.0.0.1:9", "key" => "k", "fetcher" => counter, "out" => ->(l) { said << l } })
    assert_equal 0, sent
    assert_equal ["Some lines have no host in them. Add --site https://your-site.example so they can be counted.",
                  "Sent 0 AI agent fetches from 2 new lines."], said
    assert_equal 0, @posts
  end

  def test_one_run_at_a_time_uses_a_state_file_a_crashed_runs_lock_is_taken_over_and_the_state_is_written_whole
    log = "#{@dir}/access.log"
    state = "#{@dir}/state.json"
    second = nil
    run = nil
    # While the first run sends its first batch, a second one starts on the same state file.
    fetcher = counter(lambda do |post, _n|
      if post == 1
        begin
          run.call
          second = "ran"
        rescue RuntimeError => e
          second = e.message
        end
      end
      nil
    end)
    run = -> { run_agents({ "log" => log, "to" => "http://127.0.0.1:9", "key" => "k", "site" => "https://example.com", "state" => state, "fetcher" => fetcher }) }
    File.write(log, (0...1500).map { |i| "#{line("/p#{i}", GPTBOT)}\n" }.join)
    assert_equal 1500, run.call
    assert_match(/\AAnother run is using .*state\.json \(process \d+\)\. Wait for it to finish, or delete .*state\.json\.lock if none is running\.\z/, second.to_s)
    assert_equal 1500, @stored, "each line once"
    assert_equal ["access.log", "state.json"], files, "the lock is released and no temporary file is left"

    # A lock from a process that has ended is stale.
    ended = Process.spawn(RbConfig.ruby, "-e", "")
    Process.wait(ended)
    File.write("#{state}.lock", ended.to_s)
    File.write(log, "#{line("/late", GPTBOT)}\n", mode: "a")
    assert_equal 1, run.call
    assert_equal 1501, @stored
    assert_equal ["access.log", "state.json"], files

    # A lock held by a running process is left alone.
    File.write("#{state}.lock", Process.pid.to_s)
    error = assert_raises(RuntimeError, "the lock is held") { run.call }
    assert_includes error.message, "(process #{Process.pid})"
    assert_equal Process.pid.to_s, File.read("#{state}.lock")
    File.unlink("#{state}.lock")
  end

  def test_following_a_log_that_cannot_be_read_waits_and_says_so_and_a_restart_reads_a_log_rotated_meanwhile_from_its_start
    skip "root reads every file" if Process.uid.zero?

    fetcher = counter
    log = "#{@dir}/access.log"
    state = "#{@dir}/state.json"
    File.write(log, "")
    polls = 0
    steps = {
      2 => -> { File.write(log, "#{line("/a", GPTBOT)}\n", mode: "a") },
      4 => -> { File.chmod(0, log) },
      8 => lambda do
        File.chmod(0o644, log)
        File.write(log, "#{line("/b", GPTBOT)}\n", mode: "a")
      end,
    }
    said = []
    Agents.run({ "log" => log, "to" => "http://127.0.0.1:9", "key" => "k", "site" => "https://example.com", "state" => state,
                 "follow" => true, "fetcher" => fetcher,
                 "sleep" => lambda { |_ms|
                   polls += 1
                   steps[polls]&.call
                 }, "stop" => -> { polls >= 10 }, "out" => ->(l) { said << l } })
    assert_equal 2, @stored, "it carried on once the log could be read again"
    assert_equal 1, said.count { |l| l.start_with?("Could not read") }, "said once, not every poll"
    assert_equal 0, said.count { |l| l.start_with?("Could not send") }

    # Stopped, then the log was rotated: everything in the new log is unread.
    File.rename(log, "#{log}.1")
    File.write(log, "#{line("/c", GPTBOT)}\n#{line("/d", GPTBOT)}\n")
    polls = 0
    Agents.run({ "log" => log, "to" => "http://127.0.0.1:9", "key" => "k", "site" => "https://example.com", "state" => state,
                 "follow" => true, "fetcher" => fetcher, "sleep" => ->(_ms) { polls += 1 }, "stop" => -> { polls >= 3 },
                 "out" => QUIET })
    assert_equal 4, @stored
    assert_equal ["access.log", "access.log.1", "state.json"], files
  end

  def test_a_send_that_cannot_reach_runlight_is_tried_again_on_the_next_look
    fetcher = counter(lambda do |post, _n|
      raise Runlight::Http::FetchError, "Could not connect" if post <= 2

      nil
    end)
    log = "#{@dir}/access.log"
    File.write(log, "")
    polls = 0
    said = []
    Agents.run({ "log" => log, "to" => "http://127.0.0.1:9", "key" => "k", "site" => "https://example.com", "follow" => true,
                 "fetcher" => fetcher,
                 "sleep" => lambda { |_ms|
                   polls += 1
                   File.write(log, "#{line("/a", GPTBOT)}\n") if polls == 1
                 }, "stop" => -> { polls >= 4 }, "out" => ->(l) { said << l } })
    assert_equal 1, @stored
    assert_equal ["Could not send, trying again shortly: Could not connect", "Sent 1 AI agent fetches."], said[1..]
  end

  def test_the_command_line
    run = lambda do |*args|
      out = StringIO.new
      err = StringIO.new
      fetcher = counter
      code = Runlight::Server::Cli.run(args, @dir, out, err, -> { 1_791_374_400_000 }, fetcher)
      [code, out.string, err.string, fetcher]
    end
    code, out = run.call("agents", "--help")
    assert_equal 0, code
    assert_equal Runlight::Server::Cli::AGENTS_HELP, out
    code, _, err = run.call("agents", "--log", "access.log")
    assert_equal 1, code, "no address and no key"
    assert_equal Runlight::Server::Cli::AGENTS_HELP, err
    _, help = run.call("--help")
    assert_includes help, "runlight agents --log <file>    Count AI agents from a web server's access log"

    log = "#{@dir}/access.log"
    File.write(log, "#{line("/a", GPTBOT)}\n")
    code, _, err = run.call("agents", "--log", "#{@dir}/missing.log", "--to", "https://stats.example.com", "--key", "k")
    assert_equal 1, code
    assert_equal "Runlight: No log at #{@dir}/missing.log\n", err

    # --to and --key come from config.rb when they are not given.
    File.write("#{@dir}/config.rb", '{ "RUNLIGHT_URL" => "https://stats.example.com/", "RUNLIGHT_OBSERVE_KEY" => "rlo_all" }')
    code, out, err, fetcher = run.call("agents", "--log", "#{@dir}/./access.log", "--site", "https://example.com", "--state", "#{@dir}/state.json")
    assert_equal [0, "Sent 1 AI agent fetches from 1 new lines.\n", ""], [code, out, err]
    assert_equal "https://stats.example.com/api/observe", fetcher.requests[0]["url"]
    assert_equal "Bearer rlo_all", fetcher.requests[0]["headers"]["authorization"]
    assert_equal({ "fetches" => [{ "url" => "https://example.com/a", "userAgent" => GPTBOT, "at" => utc(2026, 10, 7, 17, 55, 36) }] },
                 Json.decode(fetcher.requests[0]["body"]))
    saved = Json.decode(File.read("#{@dir}/state.json"))
    assert_equal ["ino", "offset", "head", "length"], saved.keys
    assert_equal File.size(log), saved["offset"]
    File.unlink("#{@dir}/config.rb")
  end
end
