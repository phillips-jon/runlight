# frozen_string_literal: true

module Runlight
  # Runlight as a Rack app, or as Rack middleware in front of an app, answering
  # in the order the standalone server answers: a link domain added in Settings
  # first (it leaves the dashboard's own paths alone), then `{linkPath}/{slug}`
  # on the app's own domain, then the dashboard and API under the routes' base
  # path. As middleware, every other request goes on to the app, after AI agent
  # fetches among them are recorded (observe), which returns at once for
  # everyone else.
  #
  #   # config.ru, Runlight alone
  #   run Runlight::RackApp.new(runlight: RL, base_path: "/runlight")
  #
  #   # in front of an app (Sinatra, Hanami, Roda, or any Rack app)
  #   use Runlight::RackApp, runlight: RL, base_path: "/runlight"
  #
  # The routes' options (base_path, token, accounts, origin, and the rest) are
  # passed through. Once the answer is sent, the work TS does after answering (a
  # retention change's deletions) runs in the Core's idle.
  class RackApp
    INTERNAL = Json.encode({ "error" => "Internal error", "code" => "internal" })
    private_constant :INTERNAL

    attr_reader :runlight

    # app: the app behind, when used as middleware. runlight: a Runlight::Core, or a callable that returns one
    # (so an app can build it after boot). observe: whether to record AI agent fetches of the app's pages.
    def initialize(app = nil, runlight:, observe: true, **route_options)
      @app = app
      @runlight = runlight
      @observe = observe
      @route_options = route_options
      @lock = Mutex.new
    end

    def core
      @core ||= @runlight.respond_to?(:routes) ? @runlight : @runlight.call
    end

    def routes
      @routes || @lock.synchronize { @routes ||= core.routes(@route_options) }
    end

    def call(env)
      # A request the app behind will answer keeps its body for the app; Runlight reads only its headers.
      path = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
      request = Http::Request.from_rack(env, read_body: @app.nil? || mine?(path))
      response = answer(request)
      if response.nil?
        core.observe(request) if @observe && request.method == "GET"
        return @app.call(env)
      end
      status, headers, body = response.to_rack
      body = request.method == "HEAD" ? [] : body
      [status, headers, Body.new(body, -> { idle })]
    end

    # The answer to one request, or nil when it is not Runlight's and an app sits behind.
    def answer(request)
      context = { "ip" => request.remote_address }
      linked = core.link_domain_response(request, context)
      return linked unless linked.nil?

      path = Http::Url.parse(request.url)&.pathname || "/"
      link_path = core.link_path
      if request.method == "GET" && path.match?(%r{\A#{Regexp.escape(link_path)}/[^/]+/?\z})
        return core.link_handler.call(request, context)
      end
      return routes.handle(request) if @app.nil? || mine?(path)

      nil
    rescue StandardError => e
      warn "Runlight: #{e.message}"
      Http::Response.new(INTERNAL, status: 500, headers: {
                           "content-type" => "application/json; charset=utf-8",
                           "cache-control" => "no-store",
                           "x-content-type-options" => "nosniff",
                         })
    end

    private

    def idle
      core.idle if core.respond_to?(:idle)
    rescue StandardError => e
      warn "Runlight: #{e.message}"
    end

    # Whether a path is under the routes' base path, which the dashboard, the API, and the tracker share.
    def mine?(path)
      base = Options.normalize(@route_options)["basePath"] || "/runlight"
      base = "/#{base.to_s.gsub(%r{\A/+|/+\z}, "")}"
      return true if base == "/"

      path == base || path.start_with?("#{base}/")
    end

    # A Rack body that runs a block once the server has sent it and closes it.
    class Body
      def initialize(body, after)
        @body = body
        @after = after
      end

      def each(&block)
        @body.each(&block)
      end

      def close
        @body.close if @body.respond_to?(:close)
      ensure
        @after.call
      end
    end
  end
end
