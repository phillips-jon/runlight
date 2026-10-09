# frozen_string_literal: true

require "openssl"

module Runlight
  module Accounts
    # scrypt (RFC 7914), through OpenSSL's. It gives the same bytes as Node's crypto.scrypt, so a password
    # hashed by either implementation checks out in the other.
    module Scrypt
      module_function

      # The derived key for a password and salt. Raises ArgumentError for a cost that is not a power of two
      # above 1, or r or p below 1.
      def derive(password, salt, n, r, p, length)
        raise ArgumentError, "N must be a power of two greater than 1" if n < 2 || (n & (n - 1)) != 0
        raise ArgumentError, "r, p, and the key length must be at least 1" if r < 1 || p < 1 || length < 1

        OpenSSL::KDF.scrypt(password.b, salt: salt.b, N: n, r: r, p: p, length: length)
      end
    end
  end
end
