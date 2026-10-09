defmodule Runlight.CryptoTest do
  @moduledoc "Accounts' cryptography against the crypto fixture, written by the TypeScript SDK and Node's own crypto."
  use ExUnit.Case, async: true

  alias Runlight.Crypto
  alias Runlight.Test.Fixtures

  setup_all do
    {:ok, fixture: Fixtures.php("crypto.json")}
  end

  test "scrypt gives Node's bytes", %{fixture: f} do
    for c <- f["scrypt"] do
      key = Crypto.scrypt(c["password"], Crypto.from_base64url(c["salt"]), c["N"], c["r"], c["p"], c["length"])
      assert Crypto.hex(key) == c["key"], inspect({c["password"], c["N"], c["r"], c["p"]})
    end
  end

  test "scrypt's RFC 7914 vectors" do
    assert Crypto.hex(Crypto.scrypt("", "", 16, 1, 1, 64)) ==
             "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906"
  end

  test "passwords hashed by TypeScript check here, and new hashes check", %{fixture: f} do
    for c <- f["hashes"], do: assert(Crypto.check_password(c["password"], c["hash"]), c["hash"])
    refute Crypto.check_password("a long password!", hd(f["hashes"])["hash"])

    hash = Crypto.hash_password("a long password")
    assert hash =~ ~r/\Apbkdf2\$100000\$[A-Za-z0-9_-]{22}\$[A-Za-z0-9_-]{43}\z/
    assert Crypto.check_password("a long password", hash)
    refute Crypto.check_password("another password", hash)

    for c <- f["checks"] do
      # Where TypeScript throws on a damaged hash, the check here answers false.
      want = if c["throws"], do: false, else: c["value"]
      assert Crypto.check_password(c["password"], c["stored"]) == want, "#{c["password"]} against #{c["stored"]}"
    end
  end

  test "sealed text opens both ways", %{fixture: f} do
    for c <- f["sealedByTs"] do
      assert Crypto.unseal_text(c["sealed"], c["secret"]) == c["text"]
      assert Crypto.unseal_text(Crypto.seal_text(c["text"], c["secret"]), c["secret"]) == c["text"]
    end

    for c <- f["sealedWithIv"] do
      assert Crypto.seal_text(c["text"], c["secret"], Crypto.from_base64url(c["iv"])) == c["sealed"]
    end

    for c <- f["unseal"], do: assert(Crypto.unseal_text(c["sealed"], c["secret"]) == c["result"], c["sealed"])
  end

  test "base64url and base32", %{fixture: f} do
    for c <- f["base64"],
        !c["throws"],
        do: assert(Crypto.hex(Crypto.from_base64url(c["text"])) == c["value"], c["text"])

    for c <- f["encode"] do
      bytes = Base.decode16!(c["hex"], case: :lower)
      assert Crypto.base64url(bytes) == c["base64url"]
      assert Crypto.base32(bytes) == c["base32"]
      assert Crypto.hex(Crypto.from_base64url(c["base64url"])) == c["hex"]
      assert Crypto.hex(Crypto.unbase32(c["base32"])) == c["hex"]
    end
  end

  test "totp codes", %{fixture: f} do
    for c <- f["totp"],
        !c["throws"],
        do: assert(Crypto.totp(c["secret"], c["step"]) == c["value"], "#{c["secret"]} at #{c["step"]}")

    assert Crypto.totp(Crypto.base32("12345678901234567890"), 1) == "287082"
    assert Crypto.totp(Crypto.base32("12345678901234567890"), div(1_234_567_890, 30)) == "005924"
  end

  test "otpauth uris and same text", %{fixture: f} do
    for c <- f["uris"], do: assert(Crypto.otpauth_uri(c["secret"], c["email"], c["host"]) == c["uri"])
    for c <- f["same"], do: assert(Crypto.same_text?(c["a"], c["b"]) == c["same"])

    for c <- f["signatures"] do
      assert Crypto.base64url(Crypto.hmac(:sha256, c["secret"], "#{c["body"]}.#{c["hash"]}")) == c["signature"]
    end

    for c <- f["recovery"] do
      code = c["code"] |> String.replace(~r/[^a-z0-9]/i, "") |> String.downcase()
      assert Crypto.hex(Crypto.sha256(code)) == c["hash"]
    end
  end
end
