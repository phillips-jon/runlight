# frozen_string_literal: true

require "test_helper"
require "base64"
require "fileutils"
require "net/http"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"
require "zlib"

# The server's settings, its command line, and DB-IP's monthly download, in a project folder of their own.
class ServerCliTest < Minitest::Test
  Cli = Runlight::Server::Cli
  Config = Runlight::Server::Config
  DbIp = Runlight::Server::DbIp

  EXE = File.expand_path("../../exe/runlight", __dir__)

  def setup
    @root = Dir.mktmpdir("runlight-cli-")
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def configure(settings)
    File.write("#{@root}/config.rb", settings.inspect)
  end

  # The exit code, what it printed, and what it complained.
  def cli(*args)
    out = StringIO.new
    err = StringIO.new
    code = Cli.run(args, @root, out, err, -> { 1_791_374_400_000 })
    [code, out.string, err.string]
  end

  # A port from 5160 to 5199 that nothing listens on now.
  def free_port
    (5160..5199).to_a.shuffle.each do |port|
      TCPServer.new("127.0.0.1", port).close
      return port
    rescue SystemCallError
      next
    end
    skip "no free port from 5160 to 5199"
  end

  def mode_of(path)
    File.stat(path).mode & 0o777
  end

  def test_settings_come_from_config_rb_with_paths_from_the_project_folder
    configure({ "RUNLIGHT_URL" => "https://stats.example.com", "TRUST_PROXY" => "cf-connecting-ip", "RUNLIGHT_GEO" => "off" })
    config = Config.new(@root)
    assert_equal "https://stats.example.com", config.url
    assert_equal "cf-connecting-ip", config.trust_proxy
    assert_equal "#{@root}/runlight-data", config.data_dir
    assert_equal 0o700, mode_of(config.data_dir), "the data folder is private"
    assert_nil config.geo
    assert_nil config.db_ip

    secret = config.secret
    assert_match(/\A[0-9a-f]{64}\z/, secret)
    assert_equal secret, Config.new(@root).secret, "the secret is made once and kept"
    assert_equal 0o600, mode_of("#{@root}/runlight-data/secret")

    # Symbols, numbers, and booleans read as text, and the environment comes first.
    configure({ PORT: 4000, TRUST_PROXY: false, RUNLIGHT_GEO: "off" })
    assert_equal "4000", Config.new(@root).get("PORT")
    assert_equal false, Config.new(@root).trust_proxy
    configure({ "RUNLIGHT_GEO" => "off" })
    assert_nil Config.new(@root).trust_proxy, "unset stays unset, so the default can warn"

    configure({ "RUNLIGHT_URL" => "https://stats.example.com/dashboard" })
    error = assert_raises(RuntimeError) { Config.new(@root).url }
    assert_includes error.message, "set RUNLIGHT_URL to the dashboard's address only"

    File.write("#{@root}/config.rb", '"not a hash"')
    error = assert_raises(RuntimeError) { Config.new(@root) }
    assert_includes error.message, "must return a Hash of settings"
  end

  def test_the_setup_code_is_written_down_once_and_unlocks_the_first_account
    configure({ "RUNLIGHT_URL" => "https://stats.example.com", "RUNLIGHT_GEO" => "off" })
    config = Config.new(@root)
    server = config.standalone
    text = File.read(config.setup_file)
    assert_match(%r{\AOpen this link to create the first Runlight account\. It works only while Runlight has no account\.\nhttps://stats\.example\.com/setup\?code=[A-Za-z0-9_-]{12}\n\z}, text)
    assert_equal config.setup_code, Config.new(@root).setup_code, "every process reads the same code"
    page = server.handle(Runlight::Http::Request.new("https://stats.example.com/"))
    assert_equal 403, page.status
    assert_includes page.text, "in the file setup.txt"
    assert_equal 200, server.handle(Runlight::Http::Request.new("https://stats.example.com/setup?code=#{config.setup_code}")).status

    code, out = cli("setup")
    assert_equal 0, code
    assert_equal text, out
  end

  def test_password_makes_the_owner_then_gives_a_new_password_and_turns_off_two_factor
    configure({ "RUNLIGHT_GEO" => "off" })
    code, out = cli("password", "Jon@Example.com")
    assert_equal 0, code
    assert_match(/\AAccount made, as the owner, for jon@example\.com: \S{16}\nSign in, and change it by running this again whenever you like\.\n\z/, out)
    refute File.exist?("#{@root}/runlight-data/setup.txt"), "no setup link is made for a server that has an account"

    server = Config.new(@root).standalone({}, false)
    user = server.accounts.by_email("jon@example.com")
    server.runlight.store.db.run("UPDATE rl_users SET totp_secret = ? WHERE id = ?", ["sealed", user["id"]])
    assert_equal true, server.accounts.by_email("jon@example.com")["twoFactor"]

    code, out = cli("password", "jon@example.com")
    assert_equal 0, code
    found = out.match(/: (\S+)\n/)
    assert out.start_with?("New password for jon@example.com: "), out
    assert_includes out, "Two-factor sign-in is now off for this account; turn it on again under Account.\n"
    assert_equal false, server.accounts.by_email("jon@example.com")["twoFactor"]
    refute_nil server.accounts.sign_in("jon@example.com", found[1]), "the printed password signs in"

    _, out = cli("setup")
    assert_equal "Runlight already has an account. To get into one, run runlight password <email>.\n", out

    code, _, err = cli("password")
    assert_equal 1, code
    assert_includes err, "name the account"
  end

  def test_migrate_cron_and_unknown_commands
    configure({ "RUNLIGHT_GEO" => "off" })
    code, out = cli("migrate")
    assert_equal 0, code
    assert_equal "Runlight's tables are up to date in #{@root}/runlight-data/runlight.db.\n", out
    assert File.exist?("#{@root}/runlight-data/runlight.db")

    # A setup link written before the first account goes at the next check.
    Config.new(@root).setup_code
    cli("password", "jon@example.com")
    assert_equal [0, "", ""], cli("cron"), "cron is quiet when all is well"
    refute File.exist?("#{@root}/runlight-data/setup.txt")

    code, _, err = cli("nonsense")
    assert_equal 1, code
    assert_includes err, 'unknown command "nonsense"'

    code, _, err = cli("cron", "--config", "#{@root}/missing.rb")
    assert_equal 1, code
    assert_includes err, "there is no config file at"

    _, out = cli("--version")
    assert_equal "#{Runlight::Version.version}\n", out
    _, out = cli
    assert out.start_with?("Runlight #{Runlight::Version.version}, privacy friendly web analytics"), out
  end

  def test_a_sqlite_file_gets_its_folder
    Runlight::Stores.sqlite("#{@root}/data/deeper/runlight.db").migrate
    assert File.exist?("#{@root}/data/deeper/runlight.db")
  end

  def test_db_ip_downloads_this_month_or_last_and_keeps_only_the_newest
    db = Base64.decode64(Fixtures.load("geo")["databases"][0]["base64"])
    dir = "#{@root}/geo"
    asked = []
    logged = []
    published = ["2026-09"]
    download = lambda do |url, file|
      asked << url
      release = url[/lite-(\d{4}-\d{2})\.mmdb\.gz\z/, 1]
      next false unless published.include?(release)

      File.binwrite(file, Zlib.gzip(db))
      true
    end
    geo = DbIp.new(dir, "city", download, ->(line) { logged << line })
    assert_nil geo.lookup, "nothing to look up before the first download"
    assert_nil geo.current.call("203.0.113.9"), "a running server's lookup answers nothing yet"

    october = 1_791_374_400_000 # 2026-10-07
    geo.refresh(october)
    assert_equal ["https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz",
                  "https://download.db-ip.com/free/dbip-city-lite-2026-09.mmdb.gz"], asked,
                 "a month's file appears a day or so in, so last month's stands in"
    assert_equal ["Runlight: location data from DB-IP (2026-09) is ready."], logged
    assert_equal "#{dir}/dbip-city-lite-2026-09.mmdb", geo.newest
    refute_nil geo.lookup
    assert_same geo, geo.load_newest

    published << "2026-10"
    asked = []
    geo.refresh(october)
    assert_equal ["https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz"], asked
    assert_equal ["#{dir}/dbip-city-lite-2026-10.mmdb"], Dir.glob("#{dir}/*"), "older releases go"
    asked = []
    geo.refresh(october)
    assert_equal [], asked, "once this month is there, nothing is fetched"

    # January's fallback is December of the year before, and a broken file is never kept.
    broken = DbIp.new(dir, "country", ->(_url, file) { File.binwrite(file, Zlib.gzip("not a database")).positive? }, ->(line) { logged << line })
    broken.refresh(1_798_761_600_000 + 86_400_000) # 2027-01-02
    assert_includes logged.last, "dbip-country-lite-2026-12.mmdb.gz"
    assert_nil broken.newest
  end

  # `runlight serve` as someone runs it: the server on PORT, the setup link printed, a body past the limit
  # refused, and a clean stop on SIGTERM.
  def test_serve_runs_the_server_until_it_is_stopped
    port = free_port
    log = "#{@root}/serve.log"
    env = { "PORT" => port.to_s, "HOST" => "127.0.0.1", "RUNLIGHT_GEO" => "off", "DATA_DIR" => "#{@root}/data",
            "RUNLIGHT_TOKEN" => nil, "RUNLIGHT_URL" => nil, "DATABASE_URL" => nil, "RUNLIGHT_CONFIG" => nil }
    pid = Process.spawn(env, RbConfig.ruby, EXE, "serve", chdir: @root, out: log, err: log)
    begin
      health = nil
      status = nil
      100.times do
        health = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/healthz"))
        break
      rescue SystemCallError
        # Stopped before it listened: what it said is the failure.
        _, status = Process.wait2(pid, Process::WNOHANG)
        break unless status.nil?

        sleep 0.1
      end
      refute_nil health, File.read(log)
      assert_equal ["200", "ok"], [health.code, health.body]
      printed = File.read(log)
      assert_includes printed, "Runlight #{Runlight::Version.version} is listening on http://127.0.0.1:#{port}\n"
      assert_includes printed, "Data: #{@root}/data/runlight.db\n"
      assert_match(%r{No account yet\. Open this link to create the first one:\n  http://127\.0\.0\.1:#{port}/setup\?code=[A-Za-z0-9_-]{12}\n}, printed)

      large = Net::HTTP.post(URI("http://127.0.0.1:#{port}/e"), "x" * (17 * 1024), "content-type" => "text/plain")
      assert_equal ["413", '{"error":"That request is too large"}'], [large.code, large.body]
      locked = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
      assert_equal "403", locked.code, "the dashboard waits for setup"
    ensure
      if status.nil?
        Process.kill("TERM", pid)
        _, status = Process.wait2(pid)
      end
    end
    assert status.success?, File.read(log)
  end
end
