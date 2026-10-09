# frozen_string_literal: true

# Runlight's standalone server under any Rack server (Puma, Falcon, Unicorn, or `rackup`): the dashboard at the
# root, sites managed in it, sign-in accounts, and short links on any domain pointed here. Settings come from the
# environment or from config.rb in this folder, as `runlight serve` reads them, and the scheduled check runs every
# five minutes in the server itself.
#
# Docs: https://runlight.sh/docs/ruby/

require "runlight"

run Runlight::Server::Standalone.app(__dir__)
