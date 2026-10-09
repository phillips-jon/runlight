# frozen_string_literal: true

require "openssl"
require "securerandom"

module Runlight
  # Hashes and random ids, as hash.ts makes them.
  module Hashing
    module_function

    def sha256(text)
      OpenSSL::Digest::SHA256.hexdigest(text)
    end

    # HMAC-SHA-256 of text under key, as hex.
    def hmac(key, text)
      OpenSSL::HMAC.hexdigest("SHA256", key, text)
    end

    # The day's visitor hash: SHA-256 of salt, site, IP, and user agent, cut to
    # 64 bits. The salt changes every day and old salts are deleted, so the hash
    # cannot be recomputed and does not follow anyone across days.
    def visitor_hash(salt, site, ip, ua)
      sha256("#{salt}\n#{site}\n#{ip}\n#{ua}")[0, 16]
    end

    def random_id(bytes = 12)
      SecureRandom.hex(bytes)
    end

    def random_salt
      random_id(32)
    end
  end
end
