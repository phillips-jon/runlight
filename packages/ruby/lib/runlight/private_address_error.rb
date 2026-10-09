# frozen_string_literal: true

module Runlight
  # Refused before anything was fetched, because the address is not on the public internet.
  class PrivateAddressError < RuntimeError
    def initialize(what)
      super("#{what} is not a public address")
    end
  end
end
