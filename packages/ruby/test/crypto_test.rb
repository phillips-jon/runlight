# frozen_string_literal: true

require "test_helper"

# Accounts' cryptography against the crypto fixture, written by the TypeScript SDK and Node's own crypto.
class CryptoTest < Minitest::Test
  Crypto = Runlight::Accounts::Crypto
  Scrypt = Runlight::Accounts::Scrypt

  def fixture
    Fixtures.load("crypto")
  end

  def unhex(text)
    [text].pack("H*")
  end

  def test_scrypt_gives_nodes_bytes
    fixture["scrypt"].each do |c|
      key = Scrypt.derive(c["password"], Crypto.from_base64url(c["salt"]), c["N"], c["r"], c["p"], c["length"])
      assert_equal c["key"], key.unpack1("H*"), Runlight::Json.encode([c["password"], c["N"], c["r"], c["p"], c["length"]])
    end
  end

  def test_scrypt_test_vectors_from_rfc7914
    assert_equal "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906",
                 Scrypt.derive("", "", 16, 1, 1, 64).unpack1("H*")
    assert_equal "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640",
                 Scrypt.derive("password", "NaCl", 1024, 8, 16, 64).unpack1("H*")
  end

  def test_scrypt_refuses_a_bad_cost
    assert_raises(ArgumentError) { Scrypt.derive("x", "y", 1000, 8, 1, 32) }
  end

  def test_passwords_hashed_by_type_script_check_here
    fixture["hashes"].each_with_index do |c, i|
      assert Crypto.check_password(c["password"], c["hash"]), c["hash"]
      refute Crypto.check_password("#{c["password"]}!", c["hash"]) if i.zero?
    end
  end

  def test_new_hashes_use_scrypt_and_check
    hash = Crypto.hash_password("a long password")
    assert_match(/\Ascrypt\$[A-Za-z0-9_-]{22}\$[A-Za-z0-9_-]{43}\z/, hash)
    assert Crypto.check_password("a long password", hash)
    refute_equal hash, Crypto.hash_password("a long password"), "a new salt each time"
  end

  def test_check_password_answers_as_type_script_does
    fixture["checks"].each do |c|
      label = "#{c["password"]} against #{c["stored"]}"
      if c.key?("throws")
        assert_raises(ArgumentError, "#{label} should throw") { Crypto.check_password(c["password"], c["stored"]) }
        next
      end
      assert_equal c["value"], Crypto.check_password(c["password"], c["stored"]), label
    end
  end

  def test_sealed_text_opens_both_ways
    fixture["sealedByTs"].each do |c|
      assert_equal c["text"], Crypto.unseal_text(c["sealed"], c["secret"])
      assert_equal c["text"], Crypto.unseal_text(Crypto.seal_text(c["text"], c["secret"]), c["secret"])
    end
    fixture["sealedWithIv"].each do |c|
      assert_equal c["sealed"], Crypto.seal_text(c["text"], c["secret"], Crypto.from_base64url(c["iv"]))
    end
  end

  def test_unseal_answers_as_type_script_does
    fixture["unseal"].each do |c|
      if c["result"].nil?
        assert_nil Crypto.unseal_text(c["sealed"], c["secret"]), c["sealed"]
      else
        assert_equal c["result"], Crypto.unseal_text(c["sealed"], c["secret"]), c["sealed"]
      end
    end
  end

  def test_base64_and_base32
    fixture["base64"].each do |c|
      if c.key?("throws")
        assert_raises(ArgumentError, "#{c["text"]} should throw") { Crypto.from_base64url(c["text"]) }
        next
      end
      assert_equal c["value"], Crypto.from_base64url(c["text"]).unpack1("H*"), c["text"]
    end
    fixture["encode"].each do |c|
      bytes = unhex(c["hex"])
      assert_equal c["base64url"], Crypto.base64url(bytes)
      assert_equal c["base32"], Crypto.base32(bytes)
      assert_equal c["hex"], Crypto.from_base64url(c["base64url"]).unpack1("H*")
      assert_equal c["hex"], Crypto.unbase32(c["base32"]).unpack1("H*")
    end
  end

  def test_totp_codes
    fixture["totp"].each do |c|
      label = "#{c["secret"]} at #{c["step"]}"
      if c.key?("throws")
        assert_raises(ArgumentError, "#{label} should throw") { Crypto.totp(c["secret"], c["step"].to_i) }
        next
      end
      assert_equal c["value"], Crypto.totp(c["secret"], c["step"].to_i), label
    end
  end

  def test_rfc6238_vector
    # RFC 6238's SHA-1 secret "12345678901234567890" at 59 seconds: 94287082, of which authenticator apps show the last six.
    assert_equal "287082", Crypto.totp(Crypto.base32("12345678901234567890"), 1)
    assert_equal "005924", Crypto.totp(Crypto.base32("12345678901234567890"), 1_234_567_890 / 30)
  end

  def test_match_step_allows_one_step_either_side_and_never_an_old_one
    secret = "JBSWY3DPEHPK3PXP"
    now = 1_759_900_000_000
    step = now / Crypto::STEP_MS
    assert_equal step, Crypto.match_step(secret, Crypto.totp(secret, step), now, 0)
    assert_equal step - 1, Crypto.match_step(secret, Crypto.totp(secret, step - 1), now, 0)
    assert_equal step + 1, Crypto.match_step(secret, Crypto.totp(secret, step + 1), now, 0)
    assert_nil Crypto.match_step(secret, Crypto.totp(secret, step + 2), now, 0)
    assert_nil Crypto.match_step(secret, Crypto.totp(secret, step), now, step), "a code used once is not taken again"
  end

  def test_otpauth_signatures_recovery_and_same_text
    fixture["uris"].each do |c|
      assert_equal c["uri"], Crypto.otpauth_uri(c["secret"], c["email"], c["host"])
    end
    fixture["signatures"].each do |c|
      assert_equal c["signature"], Crypto.signature(c["secret"], c["body"], c["hash"])
    end
    fixture["recovery"].each do |c|
      assert_equal c["hash"], Crypto.recovery_hash(c["code"]), c["code"]
    end
    fixture["same"].each do |c|
      assert_equal c["same"], Crypto.same_text(c["a"], c["b"])
    end
    codes = Crypto.recovery_codes
    assert_equal 10, codes.length
    codes.each { |code| assert_match(/\A[a-z2-7]{4}-[a-z2-7]{4}\z/, code) }
  end
end
