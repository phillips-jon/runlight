# frozen_string_literal: true

require "openssl"
require "securerandom"

module Runlight
  module Accounts
    # The cryptography accounts need. Passwords use scrypt, as the standalone server always has, through
    # OpenSSL's scrypt, which gives the same bytes as Node's; a PBKDF2 hash made on an edge runtime checks out too.
    #
    # Bytes are binary Strings throughout. The two-factor pieces that live in auth.ts in TypeScript (base32,
    # TOTP, the otpauth address, recovery codes, and the signature on session cookies) are here too, as
    # functions of their inputs alone, so the accounts class can call them.
    module Crypto
      SCRYPT_N = 16_384
      SCRYPT_R = 8
      SCRYPT_P = 1
      private_constant :SCRYPT_N, :SCRYPT_R, :SCRYPT_P

      # As many PBKDF2 rounds as Cloudflare Workers allow, the strictest runtime Runlight runs on.
      PBKDF2_ROUNDS = 100_000

      # Two-factor: TOTP as authenticator apps expect it (RFC 6238): SHA-1, six digits, 30 seconds.
      STEP_MS = 30_000
      BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
      private_constant :BASE32

      # The shortest stored key accepted. Ours are 32 bytes.
      MIN_KEY_BYTES = 16

      module_function

      def random_bytes(length)
        SecureRandom.random_bytes(length)
      end

      def base64url(bytes)
        [bytes].pack("m0").tr("+/", "-_").delete("=")
      end

      # Bytes from base64url (or plain base64), read as atob() reads them: white space is skipped, padding is
      # optional, and anything else that is not base64 raises ArgumentError.
      def from_base64url(text)
        plain = text.tr("-_", "+/").delete("\t\n\f\r ")
        plain = plain.sub(/={1,2}\z/, "") if (plain.length % 4).zero?
        if plain.length % 4 == 1 || !plain.match?(%r{\A[A-Za-z0-9+/]*\z})
          raise ArgumentError, "The string to be decoded is not correctly encoded."
        end

        plain.unpack1("m")
      end

      def hex(bytes)
        bytes.unpack1("H*")
      end

      def sha256(value)
        OpenSSL::Digest::SHA256.digest(value)
      end

      # hash: "SHA-1" or "SHA-256".
      def hmac(hash, key, data)
        # WebCrypto will not import an empty HMAC key.
        raise ArgumentError, "An HMAC key must not be empty" if key.empty?

        OpenSSL::HMAC.digest(hash == "SHA-1" ? "SHA1" : "SHA256", key, data)
      end

      # Compares two strings in time that does not depend on where they differ.
      def same_text(a, b)
        same_bytes(a, b)
      end

      # A password hash, in the scrypt form the standalone server has always written.
      def hash_password(password)
        salt = random_bytes(16)
        "scrypt$#{base64url(salt)}$#{base64url(scrypt(password, salt, 32))}"
      end

      # Whether a password matches a hash, scrypt or PBKDF2. A stored key under MIN_KEY_BYTES is refused,
      # since an empty or cut key would match too easily, or anything. Raises ArgumentError when a part of the
      # hash is not base64, as the TypeScript rejects then.
      def check_password(password, stored)
        parts = stored.split("$", -1)
        if parts[0] == "scrypt" && parts.length == 3
          expected = from_base64url(parts[2])
          return false if expected.bytesize < MIN_KEY_BYTES

          return same_bytes(scrypt(password, from_base64url(parts[1]), expected.bytesize), expected)
        end
        if parts[0] == "pbkdf2" && parts.length == 4
          rounds = Js.number(parts[1])
          return false if !rounds.is_a?(Integer) || rounds < 1 || rounds > 10_000_000

          expected = from_base64url(parts[3])
          return false if expected.bytesize < MIN_KEY_BYTES

          return same_bytes(pbkdf2(password, from_base64url(parts[2]), rounds, expected.bytesize), expected)
        end
        false
      end

      def scrypt(password, salt, length)
        length.zero? ? "".b : Scrypt.derive(password, salt, SCRYPT_N, SCRYPT_R, SCRYPT_P, length)
      end

      def pbkdf2(password, salt, rounds, length)
        length.zero? ? "".b : OpenSSL::KDF.pbkdf2_hmac(password.b, salt: salt.b, iterations: rounds, length: length, hash: "sha256")
      end

      def same_bytes(a, b)
        a = a.b
        b = b.b
        a.bytesize == b.bytesize && OpenSSL.fixed_length_secure_compare(a, b)
      end

      def seal_key(secret)
        sha256("totp:#{secret}")
      end

      # Seals text with AES-256-GCM under a key from the secret, as "iv.body.tag" in base64url, the form the
      # standalone server has always stored two-factor secrets in. `iv` is for tests; leave it out.
      def seal_text(text, secret, iv = nil)
        iv ||= random_bytes(12)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = seal_key(secret)
        cipher.iv_len = iv.bytesize
        cipher.iv = iv
        cipher.auth_data = ""
        body = text.empty? ? "".b : cipher.update(text)
        body += cipher.final
        "#{base64url(iv)}.#{base64url(body)}.#{base64url(cipher.auth_tag(16))}"
      end

      def unseal_text(sealed, secret)
        parts = sealed.split(".", -1)
        iv = parts[0] || ""
        body = parts[1]
        tag = parts[2]
        return nil if iv == "" || body.nil? || tag.nil? || tag == ""

        # WebCrypto reads the tag as the last 16 bytes of body and tag together, wherever the dot fell.
        joined = from_base64url(body) + from_base64url(tag)
        iv_bytes = from_base64url(iv)
        # WebCrypto refuses an IV shorter than 12 bytes.
        return nil if joined.bytesize < 16 || iv_bytes.bytesize < 12

        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = seal_key(secret)
        cipher.iv_len = iv_bytes.bytesize
        cipher.iv = iv_bytes
        cipher.auth_tag = joined.byteslice(-16, 16)
        cipher.auth_data = ""
        data = joined.byteslice(0, joined.bytesize - 16)
        plain = data.empty? ? "".b : cipher.update(data)
        plain += cipher.final
        decode_utf8(plain)
      rescue StandardError
        nil
      end

      # TextDecoder's reading: bytes that are not UTF-8 become U+FFFD, and a leading byte order mark goes.
      def decode_utf8(bytes)
        bytes = bytes.b
        bytes = bytes.byteslice(3, bytes.bytesize - 3) if bytes.start_with?("\xEF\xBB\xBF".b)
        Js.scrub(bytes)
      end

      def base32(bytes)
        bits = 0
        value = 0
        out = +""
        bytes.each_byte do |byte|
          # Only the low bits are ever read, so the rest are dropped before they grow.
          value = ((value << 8) | byte) & 0xffff
          bits += 8
          while bits >= 5
            out << BASE32[(value >> (bits - 5)) & 31]
            bits -= 5
          end
        end
        out << BASE32[(value << (5 - bits)) & 31] if bits.positive?
        out
      end

      # Bytes from base32, skipping anything that is not a base32 letter, as authenticator apps' secrets come.
      def unbase32(text)
        bits = 0
        value = 0
        out = "".b
        Js.upper(Js.scrub(text).sub(/=+\z/, "")).each_char do |c|
          i = c.bytesize == 1 ? BASE32.index(c) : nil
          next if i.nil?

          value = ((value << 5) | i) & 0xffff
          bits += 5
          if bits >= 8
            out << ((value >> (bits - 8)) & 255).chr
            bits -= 8
          end
        end
        out
      end

      # The six-digit code for a secret at a time step.
      def totp(secret, step)
        mac = hmac("SHA-1", unbase32(secret), [step].pack("q>")).bytes
        at = mac[19] & 15
        n = ((mac[at] & 127) << 24) | (mac[at + 1] << 16) | (mac[at + 2] << 8) | mac[at + 3]
        (n % 1_000_000).to_s.rjust(6, "0")
      end

      # The time step a code matches, one step either side for clocks that drift, newer than `after`; else nil.
      def match_step(secret, code, now, after)
        current = now.floor.div(STEP_MS)
        [current, current - 1, current + 1].each do |step|
          return step if step > after && totp(secret, step) == code
        end
        nil
      end

      # The address an authenticator app reads from the QR code.
      def otpauth_uri(secret, email, host)
        label = Js.encode_uri_component("Runlight (#{host}):#{email}")
        "otpauth://totp/#{label}?secret=#{secret}&issuer=#{Js.encode_uri_component("Runlight (#{host})")}&algorithm=SHA1&digits=6&period=30"
      end

      # Ten one-use recovery codes, like "k7dq-2mfa".
      def recovery_codes
        Array.new(10) do
          raw = base32(random_bytes(5)).downcase
          "#{raw[0, 4]}-#{raw[4, 4]}"
        end
      end

      # What a recovery code is kept as: SHA-256 of its letters and digits in lower case, so dashes and case do not matter.
      def recovery_hash(code)
        hex(sha256(Js.scrub(code).gsub(/[^a-z0-9]/i, "").downcase))
      end

      # The signature on a session, sign-in, or device value: HMAC-SHA-256 of "body.hash" under the install's secret.
      def signature(secret, body, hash)
        base64url(hmac("SHA-256", secret, "#{body}.#{hash}"))
      end

      private_class_method :scrypt, :pbkdf2, :same_bytes, :seal_key, :decode_utf8
    end
  end
end
