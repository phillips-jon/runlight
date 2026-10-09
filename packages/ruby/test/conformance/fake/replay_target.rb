# frozen_string_literal: true

require_relative "../target"
require_relative "../player"
require_relative "../zip"
require_relative "denormalizer"

module Conformance
  module Fake
    # A stand-in for the Ruby core that answers each step, deliberately, with the
    # answer http.json expects of it: placeholders filled with fresh values, ZIP
    # files zipped, the requests to other servers made through the runner's
    # fetcher, and Set-Cookie lines with values for the jars. Replaying every
    # scenario through it proves the runner itself (normalizing, captures, jars,
    # templates, ZIP reading, and the fetched record) before the core exists.
    #
    # It also checks what it is sent: the entry point, method, and URL each step
    # names, no template left unfilled, and nothing read from the environment.
    class ReplayTarget
      include Target

      attr_reader :idled, :requests, :runlight_options, :routes_options

      def initialize(scenario, runlight_options, routes_options, values = Denormalizer.new)
        raise "routes() must be given the token, nil included" unless routes_options.key?("token")

        @scenario = scenario
        @runlight_options = runlight_options
        @routes_options = routes_options
        @values = values
        @at = 0
        @idled = 0
        @requests = []
        @fetcher = runlight_options["fetcher"]
        @now = runlight_options["now"]
      end

      def handle(request)
        answer("routes", request) || raise("The routes always answer")
      end

      def links(request)
        answer("links", request) || raise("The link handler always answers")
      end

      def link_domain(request)
        answer("linkDomain", request)
      end

      def idle
        @idled += 1
      end

      private

      def answer(to, request)
        step = @scenario["steps"][@at] || raise("More requests than steps")
        @at += 1
        @requests << request
        check(step, to, request)
        expect = step["expect"]

        (expect["fetched"] || []).each { |fetched| fetch(fetched) }
        return nil if Player.filled?(expect["pass"])

        headers = {}
        (expect["headers"] || {}).each do |name, value|
          headers[name] =
            if name == "set-cookie" then value.map { |line| @values.cookie(line.to_s) }
            elsif name == "content-type" then value
            else @values.text(value.to_s)
            end
        end
        body =
          if expect.key?("files")
            files = expect["files"].map { |f| { "name" => f["name"], "text" => @values.text(f["text"]) } }
            # Every other ZIP is stored rather than deflated, so both are read.
            Zip.zip(files, deflate: @at.even?)
          elsif expect.key?("body")
            Runlight::Json.encode(@values.value(expect["body"]))
          elsif expect.key?("text")
            @values.text(expect["text"])
          elsif expect.key?("found")
            # A page that holds the look strings found and none of the others, and is not JSON.
            "<!-- a page -->\n#{step["look"].zip(expect["found"]).select { |_, f| f }.map(&:first).join("\n")}"
          else
            ""
          end
        Runlight::Http::Response.new(body, status: Integer(expect["status"]), headers: headers)
      end

      def check(step, to, request)
        where = "step #{@at} (#{step["method"]} #{step["path"]})"
        raise "#{where} went to #{to}" if (step["to"] || "routes") != to
        raise "#{where} was sent as #{request.method}" if request.method != step["method"].upcase

        unless step["path"].include?("{{")
          prefix = to == "routes" && !Player.filled?(step["absolute"]) ? "/runlight" : ""
          url = Runlight::Http::Url.new("https://#{step["host"] || "example.com"}#{prefix}#{step["path"]}").href
          raise "#{where} was sent to #{request.url}" if request.url != url
        end
        sent = "#{request.url}\n#{request.text}"
        request.headers.each { |_, value| sent += "\n#{value}" }
        raise "#{where} still holds a template: #{sent}" if sent.include?("{{")

        Player::ENV_NAMES.each do |name|
          raise "#{where} can read #{name}" unless Runlight::Env.get(name).nil?
        end
        raise "#{where}: the clock is not whole milliseconds" unless @now.call.is_a?(Integer)
      end

      # Makes one of the requests the step expects, through the runner's fetcher, as the core would.
      def fetch(fetched)
        fetched = @values.value(fetched)
        headers = fetched["headers"] || {}
        init = { "method" => fetched["method"], "headers" => headers }
        if fetched.key?("body")
          type = headers["content-type"] || ""
          sent = fetched["body"]
          init["body"] =
            if sent.is_a?(String) then sent
            elsif sent.is_a?(Hash) && type.start_with?("application/x-www-form-urlencoded")
              Runlight::Http::SearchParams.new(sent.transform_values { |v| Runlight::Js.string(v) }).to_s
            else Runlight::Json.encode(sent)
            end
        end
        begin
          @fetcher.fetch(fetched["url"], init).text
        rescue Runlight::Http::FetchError, Runlight::Http::BodyTooLong
          # A server that did not answer: the core carries on, as the TypeScript one did.
          nil
        end
      end
    end
  end
end
