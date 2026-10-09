# frozen_string_literal: true

require_relative "runlight/version"
require_relative "runlight/undefined"

# Privacy friendly web analytics that lives inside your Ruby app: the Ruby port
# of the runlight npm package, with the same tables, the same HTTP answers byte
# for byte, and the same dashboard.
#
#   RL = Runlight.new(store: Runlight::Stores.sqlite("db/runlight.sqlite3"),
#                     site: { name: "Example", hostnames: ["example.com"] })
#   app = RL.rack_app(base_path: "/runlight")
#
# Every class loads on first use.
module Runlight
  autoload :Assistant, "runlight/assistant"
  autoload :AssistantError, "runlight/assistant_error"
  autoload :Body, "runlight/body"
  autoload :Brand, "runlight/brand"
  autoload :Connect, "runlight/connect"
  autoload :ConnectError, "runlight/connect_error"
  autoload :Core, "runlight/core"
  autoload :Dates, "runlight/dates"
  autoload :Env, "runlight/env"
  autoload :FunnelError, "runlight/funnel_error"
  autoload :Funnels, "runlight/funnels"
  autoload :Geo, "runlight/geo"
  autoload :GoalError, "runlight/goal_error"
  autoload :Goals, "runlight/goals"
  autoload :Hashing, "runlight/hashing"
  autoload :Icon, "runlight/icon"
  autoload :Intl, "runlight/intl"
  autoload :Journeys, "runlight/journeys"
  autoload :Js, "runlight/js"
  autoload :Json, "runlight/json"
  autoload :LinkError, "runlight/link_error"
  autoload :Links, "runlight/links"
  autoload :Mcp, "runlight/mcp"
  autoload :McpError, "runlight/mcp_error"
  autoload :Messages, "runlight/messages"
  autoload :Mmdb, "runlight/mmdb"
  autoload :OAuth, "runlight/oauth"
  autoload :Options, "runlight/options"
  autoload :Payload, "runlight/payload"
  autoload :PrivateAddressError, "runlight/private_address_error"
  autoload :Query, "runlight/query"
  autoload :RackApp, "runlight/rack_app"
  autoload :RateLimit, "runlight/rate_limit"
  autoload :Reports, "runlight/reports"
  autoload :Routes, "runlight/routes"
  autoload :Safefetch, "runlight/safefetch"
  autoload :SettingsError, "runlight/settings_error"
  autoload :Sources, "runlight/sources"
  autoload :Ua, "runlight/ua"
  autoload :Zip, "runlight/zip"

  module Accounts
    autoload :AccountError, "runlight/accounts/account_error"
    autoload :Accounts, "runlight/accounts/accounts"
    autoload :Crypto, "runlight/accounts/crypto"
    autoload :Pages, "runlight/accounts/pages"
    autoload :Scrypt, "runlight/accounts/scrypt"
    autoload :Throttle, "runlight/accounts/throttle"
    autoload :Web, "runlight/accounts/web"
  end

  module Data
    autoload :Agents, "runlight/data/agents"
    autoload :Sources, "runlight/data/sources"
  end

  module Db
    autoload :Connect, "runlight/db/connect"
    autoload :Database, "runlight/db/db"
    autoload :Pools, "runlight/db/connect"
  end

  module Http
    autoload :BodyTooLong, "runlight/http/errors"
    autoload :FetchError, "runlight/http/errors"
    autoload :Headers, "runlight/http/headers"
    autoload :Idna, "runlight/http/url"
    autoload :NetFetcher, "runlight/http/fetcher"
    autoload :Request, "runlight/http/request"
    autoload :Response, "runlight/http/response"
    autoload :SearchParams, "runlight/http/search_params"
    autoload :Url, "runlight/http/url"
  end

  module Importers
    autoload :Bitly, "runlight/importers/bitly"
    autoload :Client, "runlight/importers/client"
    autoload :CsvVisits, "runlight/importers/csv_visits"
    autoload :Dub, "runlight/importers/dub"
    autoload :HttpError, "runlight/importers/http_error"
    autoload :ImportError, "runlight/importers/import_error"
    autoload :Importer, "runlight/importers/importer"
    autoload :Index, "runlight/importers/index"
    autoload :Rebrandly, "runlight/importers/rebrandly"
    autoload :Shortio, "runlight/importers/shortio"
    autoload :Umami, "runlight/importers/umami"
    autoload :Visits, "runlight/importers/visits"
    autoload :Write, "runlight/importers/write"
  end

  module Mail
    autoload :MailError, "runlight/mail/mail_error"
    autoload :Secret, "runlight/mail/secret"
    autoload :Ses, "runlight/mail/ses"
    autoload :Smtp, "runlight/mail/smtp"
    autoload :SmtpSession, "runlight/mail/smtp_session"
    autoload :Transports, "runlight/mail/transports"
  end

  module Server
    autoload :Agents, "runlight/server/agents"
    autoload :Cli, "runlight/server/cli"
    autoload :Config, "runlight/server/config"
    autoload :DbIp, "runlight/server/db_ip"
    autoload :SendError, "runlight/server/send_error"
    autoload :Standalone, "runlight/server/standalone"
  end

  module Store
    autoload :Sql, "runlight/store/sql"
    autoload :SqlStore, "runlight/store/sql_store"
  end

  autoload :Stores, "runlight/stores"

  # A Runlight for an app: Runlight.new(store: ..., site: ...) is Runlight::Core.new with the same options.
  def self.new(options = {}, **keywords)
    Core.new(options.merge(keywords))
  end
end
