# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Runlight
  module Server
    # The commands behind exe/runlight, the Ruby counterpart of `npx runlight.sh`'s: the server itself, the
    # scheduled check for a crontab, a new password for someone locked out, the tables, the setup link, and the
    # access log reader for AI agents.
    module Cli
      HELP = <<~TEXT
        Runlight %s, privacy friendly web analytics for any number of sites.

        Usage:
          runlight serve                  Start the server
          runlight cron                   Run the scheduled check, and fetch this month's location data
          runlight password <email>       Make an account, or give one a new password
          runlight setup                  Print the link that makes the first account
          runlight migrate                Create or update Runlight's tables
          runlight agents --log <file>    Count AI agents from a web server's access log
          runlight --version              Print the version

        Add --config <file> to read settings from a config.rb other than the
        project folder's. Settings are read from the environment first and then
        config.rb: PORT, HOST, DATA_DIR, DATABASE_URL, RUNLIGHT_SECRET,
        RUNLIGHT_TOKEN, RUNLIGHT_URL, TRUST_PROXY, RUNLIGHT_GEO, CRON_SECRET, and
        RUNLIGHT_OBSERVE_KEY.

        The server runs the scheduled check every five minutes. To run it from
        cron as well, or for a server that is not always running:
          */5 * * * * cd /path/to/project && bundle exec runlight cron

        Docs: https://runlight.sh/docs/ruby/
      TEXT

      AGENTS_HELP = <<~TEXT
        Count AI agents on a site that has only the script tag, from its web server's log.

        Usage:
          runlight agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_...

          --log <file>    The access log, in nginx or Apache's combined format, or Caddy's JSON
          --to <url>      Your Runlight, as its dashboard address (or RUNLIGHT_URL)
          --key <key>     The site's key from Settings, Install, Key for CMS plugins (or RUNLIGHT_OBSERVE_KEY)
          --site <url>    The site's address, such as https://example.com, when the log has no host in it
          --follow        Keep running and send fetches as they happen
          --state <file>  Remember where it stopped, so the next run, or a restarted --follow, starts there.
                          Only one run at a time can use it.

        Docs: https://runlight.sh/docs/ruby/#ai-agents-from-a-log
      TEXT

      module_function

      # Runs one command and returns the exit code. args: the arguments after the program's name. root: the project
      # folder, which holds config.rb. out and err: where it writes. now: a callable returning epoch milliseconds.
      # fetcher: reaches Runlight for the agents command, Http::NetFetcher by default.
      def run(args, root, out = $stdout, err = $stderr, now = nil, fetcher = nil)
        args = args.dup
        now ||= -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
        file = nil
        at = args.index("--config")
        unless at.nil?
          file = args[at + 1]
          if file.nil?
            err.write("Runlight: name the file after --config.\n")
            return 1
          end
          args.slice!(at, 2)
          file = begin
            File.realpath(file)
          rescue SystemCallError
            file
          end
        end
        command = args[0] || "help"
        begin
          case command
          when "help", "--help", "-h"
            out.write(format(HELP, Version.version))
            0
          when "--version", "-v"
            out.write("#{Version.version}\n")
            0
          when "serve"
            serve(Config.new(root, file), out, err, now)
          when "cron"
            cron(Config.new(root, file), err, now)
          when "password"
            password(Config.new(root, file), args[1], out, err, now)
          when "setup"
            setup(Config.new(root, file), out)
          when "agents"
            agents(args[1..], root, file, out, err, now, fetcher)
          when "migrate"
            config = Config.new(root, file)
            rl = config.standalone({ "now" => now }, false).runlight
            rl.init
            rl.store.migrate(true)
            out.write("Runlight's tables are up to date in #{config.where}.\n")
            0
          else
            err.write("Runlight: unknown command \"#{command}\". Run runlight --help.\n")
            1
          end
        rescue StandardError, ScriptError => e
          err.write("Runlight: #{e.message}\n")
          1
        end
      end

      # The server, on PORT (3000) at HOST (0.0.0.0), with Puma when it is installed and WEBrick otherwise. It runs
      # the scheduled check every five minutes, and stops on SIGINT or SIGTERM.
      def serve(config, out, err, now)
        handler, name = rack_handler
        port = Js.number(config.get("PORT") || "3000")
        raise RuntimeError, "set PORT to a port number, such as 3000" unless port.is_a?(Integer) && port.between?(0, 65_535)

        host = config.get("HOST") || "0.0.0.0"
        server = config.standalone({ "now" => now })
        server.runlight.init
        shown = ["0.0.0.0", "::"].include?(host) ? "localhost" : host
        options = { Host: host, Port: port }
        if name == "puma"
          options[:Silent] = true
        else
          require "webrick"
          options[:Logger] = WEBrick::Log.new(err, WEBrick::Log::WARN)
          options[:AccessLog] = []
        end
        server.schedule(config)
        begin
          handler.run(server, **options) do |running|
            if name != "puma"
              %w[INT TERM].each { |signal| Signal.trap(signal) { running.shutdown } }
            end
            out.write("Runlight #{Version.version} is listening on http://#{shown}:#{port}\n")
            out.write("Data: #{config.where}\n")
            if server.accounts.count.zero?
              code = config.setup_code
              out.write(if code.nil?
                          "\nNo account yet. Open http://#{shown}:#{port}/setup and enter RUNLIGHT_TOKEN to create the first one.\n\n"
                        else
                          "\nNo account yet. Open this link to create the first one:\n  http://#{shown}:#{port}/setup?code=#{code}\n\n"
                        end)
            end
            out.flush if out.respond_to?(:flush)
          end
        ensure
          server.stop
          config.store.close if config.store.respond_to?(:close)
        end
        0
      end

      # Rack's handler for Puma when it is installed, else WEBrick's, and its name.
      def rack_handler
        handlers = begin
          require "rackup"
          ::Rackup::Handler
        rescue LoadError
          require "rack"
          require "rack/handler" unless defined?(::Rack::Handler)
          ::Rack::Handler
        end
        begin
          require "puma"
          [handlers.get("puma"), "puma"]
        rescue LoadError
          [handlers.get("webrick"), "webrick"]
        end
      rescue LoadError, NameError
        raise RuntimeError, "add rackup (or rack 2), and puma or webrick, to your Gemfile to run the server."
      end

      # The scheduled check (salts, email reports, retention, and rollups), then this month's location data. Quiet
      # when all is well, as cron likes. A run that starts while another is still going leaves it to that one.
      def cron(config, err, now)
        lock = begin
          File.open("#{config.data_dir}/cron.lock", File::RDWR | File::CREAT, 0o600)
        rescue SystemCallError
          nil
        end
        return 0 if !lock.nil? && !lock.flock(File::LOCK_EX | File::LOCK_NB)

        begin
          server = config.standalone({ "now" => now }, false)
          result = server.check
          # The setup link is no use once someone has an account.
          FileUtils.rm_f(config.setup_file) if File.file?(config.setup_file) && server.accounts.count.positive?
          failed = result["reports"]["failed"]
          if failed.positive?
            err.write("Runlight: #{failed} email #{failed == 1 ? "report" : "reports"} could not be sent. " \
                      "The dashboard's Settings, Email reports, says why.\n")
          end
          config.db_ip&.refresh(now.call)
          failed.positive? ? 1 : 0
        ensure
          unless lock.nil?
            lock.flock(File::LOCK_UN)
            lock.close
          end
        end
      end

      # A new password for someone locked out, which also turns off their two-factor sign-in, since someone at
      # the server is who they say. It makes the account when there is none: the owner on a server with nobody
      # yet, and an admin otherwise.
      def password(config, email, out, err, now)
        if email.nil? || Js.trim(email) == ""
          err.write("Runlight: name the account, as in runlight password you@example.com\n")
          return 1
        end
        server = config.standalone({ "now" => now }, false)
        server.runlight.init
        password = Accounts::Crypto.base64url(SecureRandom.random_bytes(12))
        existed = !server.accounts.by_email(email).nil?
        user = server.accounts.set_password(email, password, now.call)
        reset = user["twoFactor"] ? true : false
        server.accounts.disable_two_factor(user["id"]) if reset
        who = Js.lower(Js.trim(email))
        made = existed ? "New password" : "Account made, as #{user["role"] == "owner" ? "the owner" : "an admin"},"
        out.write("#{made} for #{who}: #{password}\n" \
                  "#{reset ? "Two-factor sign-in is now off for this account; turn it on again under Account.\n" : ""}" \
                  "Sign in, and change it by running this again whenever you like.\n")
        0
      end

      # Reads a web server's access log and sends the AI agent fetches in it to a Runlight, as `npx runlight.sh
      # agents` does. --to and --key default to RUNLIGHT_URL and RUNLIGHT_OBSERVE_KEY, from the environment or
      # config.rb. With --follow it runs until it is stopped, and a stop by SIGINT or SIGTERM releases the
      # state file's lock on the way out.
      def agents(args, root, file, out, err, now, fetcher)
        flag = lambda do |name|
          at = args.index("--#{name}")
          at.nil? ? nil : args[at + 1]
        end
        if args.include?("--help") || args.include?("-h")
          out.write(AGENTS_HELP)
          return 0
        end
        log = flag.call("log")
        to = flag.call("to")
        key = flag.call("key")
        if to.nil? || key.nil?
          config = Config.new(root, file)
          to ||= config.get("RUNLIGHT_URL")
          key ||= config.get("RUNLIGHT_OBSERVE_KEY")
        end
        if log.nil? || log == "" || to.nil? || to == "" || key.nil? || key == ""
          err.write(AGENTS_HELP)
          return 1
        end
        follow = args.include?("--follow")
        stopped = false
        previous = {}
        if follow
          %w[INT TERM].each do |signal|
            previous[signal] = Signal.trap(signal) { stopped = true }
          rescue ArgumentError
            nil
          end
        end
        site = flag.call("site")
        state = flag.call("state")
        options = {
          "log" => absolute(log),
          "to" => to,
          "key" => key,
          "follow" => follow,
          "out" => ->(line) { out.write("#{line}\n") },
          "stop" => -> { stopped },
          "now" => now,
        }
        options["site"] = site unless site.nil? || site == ""
        options["state"] = absolute(state) unless state.nil? || state == ""
        options["fetcher"] = fetcher unless fetcher.nil?
        begin
          Agents.run(options)
        ensure
          previous.each { |signal, handler| Signal.trap(signal, handler || "DEFAULT") }
        end
        0
      end

      # A path made absolute from the working folder, with . and .. resolved, as Node's path.resolve does.
      def absolute(path)
        path = path.start_with?("/") ? path : "#{Dir.pwd}/#{path}"
        parts = []
        path.split("/").each do |part|
          next if part == "" || part == "."

          part == ".." ? parts.pop : parts << part
        end
        "/#{parts.join("/")}"
      end

      def setup(config, out)
        server = config.standalone({}, false)
        server.runlight.init
        if server.accounts.count.positive?
          out.write("Runlight already has an account. To get into one, run runlight password <email>.\n")
          return 0
        end
        unless config.get("RUNLIGHT_TOKEN").nil?
          out.write("Open /setup at your Runlight's address and enter RUNLIGHT_TOKEN to create the first account.\n")
          return 0
        end
        config.setup_code
        out.write(File.read(config.setup_file))
        if config.url.nil?
          out.write("Put your Runlight's own address in place of https://your-runlight-address, or set RUNLIGHT_URL.\n")
        end
        0
      end

      private_class_method :serve, :rack_handler, :cron, :password, :agents, :absolute, :setup
    end
  end
end
