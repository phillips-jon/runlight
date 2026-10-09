# frozen_string_literal: true

module Conformance
  # The entry points a scenario's steps go to: the Ruby core (CoreTarget), or a fake that proves the runner.
  module Target
    # The routes' handler, core.routes(...).handle.
    def handle(_request)
      raise NotImplementedError
    end

    # The app's own short-link path, core.link_handler.
    def links(_request)
      raise NotImplementedError
    end

    # The link-domain middleware, core.link_domain_response; nil lets the request pass on to the app.
    def link_domain(_request)
      raise NotImplementedError
    end

    # Finishes work a request started after answering (retention), as `await rl.idle()` does in TypeScript.
    def idle; end
  end
end
