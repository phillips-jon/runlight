# frozen_string_literal: true

module Runlight
  module Server
    # A failure to reach Runlight or have it take a batch, told apart from a failure to read the log.
    class SendError < RuntimeError
    end
  end
end
