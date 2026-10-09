# frozen_string_literal: true

require "openssl"
require "securerandom"

module Runlight
  module Mail
    # Keys kept in the database (the mail service's, the AI Assistant's, and the tokens for connected
    # installs) are encrypted with AES-GCM, under a key derived from a secret only the server has:
    # `RUNLIGHT_SECRET`, or else the dashboard token. A copied database alone does not give them away.
    # The label says "mail" because mail came first; changing it would make every saved key unreadable.
    #
    # The sealed form is Web Crypto's: base64 of the 12 byte IV, and base64 of the ciphertext followed
    # by its 16 byte tag, so either implementation opens what the other sealed.
    module Secret
      module_function

      def key_for(secret)
        OpenSSL::Digest::SHA256.digest("runlight-mail:#{secret}")
      end

      # `v1:<iv>:<ciphertext>`, or `plain:<json>` when the server has no secret to encrypt with.
      def seal(value, secret)
        return "plain:#{value}" if secret.nil? || secret == ""

        iv = SecureRandom.random_bytes(12)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = key_for(secret)
        cipher.iv = iv
        cipher.auth_data = ""
        data = value.to_s.empty? ? "".b : cipher.update(value.to_s)
        data += cipher.final
        "v1:#{[iv].pack("m0")}:#{[data + cipher.auth_tag(16)].pack("m0")}"
      end

      # The sealed value, or nil when it cannot be opened (a different secret, or damaged).
      def unseal(sealed, secret)
        return sealed[6..] if sealed.start_with?("plain:")

        parts = sealed.split(":", -1)
        version = parts[0]
        iv = parts[1] || ""
        data = parts[2] || ""
        return nil if version != "v1" || iv == "" || data == "" || secret.nil? || secret == ""

        iv = decode64(iv)
        data = decode64(data)
        return nil if iv.nil? || iv.empty? || data.nil? || data.bytesize < 16

        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = key_for(secret)
        cipher.iv_len = iv.bytesize
        cipher.iv = iv
        cipher.auth_tag = data.byteslice(-16, 16)
        cipher.auth_data = ""
        body = data.byteslice(0, data.bytesize - 16)
        plain = body.empty? ? "".b : cipher.update(body)
        plain += cipher.final
        Body.utf8(plain)
      rescue OpenSSL::Cipher::CipherError, ArgumentError
        nil
      end

      # Strict base64, as base64_decode(text, true) reads it: nil for anything outside the alphabet.
      def decode64(text)
        return nil unless text.match?(%r{\A[A-Za-z0-9+/]*={0,2}\z}) && text.delete("=").length % 4 != 1

        text.unpack1("m")
      end

      private_class_method :key_for, :decode64
    end
  end
end
