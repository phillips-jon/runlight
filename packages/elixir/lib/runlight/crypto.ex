defmodule Runlight.Crypto do
  @moduledoc false
  # Internal. The cryptography accounts and saved keys need (the SDK's
  # accounts/crypto.ts and mail/secret.ts): byte-identical formats, so one
  # database can be served by either implementation.
  #
  # Passwords are hashed with PBKDF2-SHA-256 (100,000 rounds, the SDK's own
  # second form), which Erlang's crypto computes natively; a scrypt hash
  # written by the Node SDK still checks out, through the scrypt here.

  import Bitwise

  @doc "`length` random bytes."
  @spec random_bytes(pos_integer()) :: binary()
  def random_bytes(length), do: :crypto.strong_rand_bytes(length)

  @doc "base64url without padding."
  @spec base64url(binary()) :: String.t()
  def base64url(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "The bytes of base64url text, forgiving as atob is of missing padding; nil when it is not base64."
  @spec from_base64url(String.t()) :: binary() | nil
  def from_base64url(text) do
    text = text |> String.replace("-", "+") |> String.replace("_", "/")
    atob(text)
  end

  @doc "`atob`: forgiving base64 (spaces dropped, padding optional) to bytes, or nil where it throws."
  @spec atob(String.t()) :: binary() | nil
  def atob(text) do
    text = String.replace(text, ~r/[\t\n\f\r ]/, "")
    text = if rem(byte_size(text), 4) == 0, do: String.replace(text, ~r/={1,2}\z/, ""), else: text

    if rem(byte_size(text), 4) == 1 or Regex.match?(~r/[^A-Za-z0-9+\/]/, text) do
      nil
    else
      case Base.decode64(text, padding: false) do
        {:ok, bytes} -> bytes
        :error -> nil
      end
    end
  end

  @doc "Lowercase hex."
  @spec hex(binary()) :: String.t()
  def hex(bytes), do: Base.encode16(bytes, case: :lower)

  @doc "SHA-256 of text or bytes."
  @spec sha256(iodata()) :: binary()
  def sha256(value), do: :crypto.hash(:sha256, value)

  @doc "HMAC with SHA-1 or SHA-256."
  @spec hmac(:sha | :sha256, iodata(), iodata()) :: binary()
  def hmac(hash, key, data), do: :crypto.mac(:hmac, hash, key, data)

  @doc "Compares two strings in time that does not depend on where they differ."
  @spec same_text?(String.t(), String.t()) :: boolean()
  def same_text?(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b), else: false
  end

  def same_text?(_, _), do: false

  @doc """
  Compares two strings as the routes' constantTimeEqual does: lengths in
  UTF-16 units first, then every unit.
  """
  @spec constant_time_equal?(String.t(), String.t()) :: boolean()
  def constant_time_equal?(a, b) do
    ua = Runlight.JS.units(a)
    ub = Runlight.JS.units(b)
    byte_size(ua) == byte_size(ub) and :crypto.hash_equals(ua, ub)
  end

  # Passwords

  @pbkdf2_rounds 100_000
  # The shortest stored key accepted. Ours are 32 bytes; an empty or cut key would match too easily, or anything.
  @min_key_bytes 16

  @doc "A password hash in the SDK's PBKDF2 form: pbkdf2$rounds$salt$key."
  @spec hash_password(String.t()) :: String.t()
  def hash_password(password) do
    salt = random_bytes(16)
    "pbkdf2$#{@pbkdf2_rounds}$#{base64url(salt)}$#{base64url(pbkdf2(password, salt, @pbkdf2_rounds, 32))}"
  end

  @doc "Whether a password matches a hash, in either of the SDK's forms."
  @spec check_password(String.t(), String.t()) :: boolean()
  def check_password(password, stored) do
    case String.split(stored, "$") do
      ["scrypt", salt, key] ->
        with expected when is_binary(expected) and byte_size(expected) >= @min_key_bytes <- from_base64url(key),
             salt when is_binary(salt) <- from_base64url(salt) do
          same_bytes?(scrypt(password, salt, 16_384, 8, 1, byte_size(expected)), expected)
        else
          _ -> false
        end

      ["pbkdf2", rounds, salt, key] ->
        n = Runlight.JS.number(rounds)

        with true <- Runlight.JS.integer?(n) and n >= 1 and n <= 10_000_000,
             n = trunc(n),
             expected when is_binary(expected) and byte_size(expected) >= @min_key_bytes <- from_base64url(key),
             salt when is_binary(salt) <- from_base64url(salt) do
          same_bytes?(pbkdf2(password, salt, n, byte_size(expected)), expected)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp same_bytes?(a, b), do: byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)

  @doc false
  def pbkdf2(password, salt, rounds, length), do: :crypto.pbkdf2_hmac(:sha256, password, salt, rounds, length)

  @doc """
  scrypt (RFC 7914), for hashes the Node SDK wrote. Slow in plain Elixir,
  about a second for N = 16384, so only an account made by Node pays it, once.
  """
  @spec scrypt(binary(), binary(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) :: binary()
  def scrypt(password, salt, n, r, p, length) do
    b = pbkdf2(password, salt, 1, p * 128 * r)

    mixed =
      for i <- 0..(p - 1), into: <<>> do
        romix(binary_part(b, i * 128 * r, 128 * r), n, r)
      end

    pbkdf2(password, mixed, 1, length)
  end

  defp romix(block, n, r) do
    x = words(block)
    {v, x} = Enum.map_reduce(1..n, x, fn _, x -> {x, block_mix(x, r)} end)
    v = List.to_tuple(v)

    x =
      Enum.reduce(1..n, x, fn _, x ->
        j = integerify(x, r) &&& n - 1
        block_mix(xor_words(x, elem(v, j)), r)
      end)

    for w <- Tuple.to_list(x), into: <<>>, do: <<w::little-32>>
  end

  defp words(block), do: List.to_tuple(for <<w::little-32 <- block>>, do: w)

  defp integerify(x, r), do: elem(x, (2 * r - 1) * 16)

  defp xor_words(a, b) do
    List.to_tuple(for i <- 0..(tuple_size(a) - 1), do: bxor(elem(a, i), elem(b, i)))
  end

  defp block_mix(b, r) do
    last = for i <- 0..15, do: elem(b, (2 * r - 1) * 16 + i)

    {ys, _} =
      Enum.map_reduce(0..(2 * r - 1), List.to_tuple(last), fn i, x ->
        block = List.to_tuple(for k <- 0..15, do: bxor(elem(x, k), elem(b, i * 16 + k)))
        y = salsa8(block)
        {y, y}
      end)

    ys = List.to_tuple(ys)
    evens = for i <- 0..(r - 1), do: Tuple.to_list(elem(ys, 2 * i))
    odds = for i <- 0..(r - 1), do: Tuple.to_list(elem(ys, 2 * i + 1))
    List.to_tuple(List.flatten(evens ++ odds))
  end

  defp salsa8(input) do
    {x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15} = input
    state = rounds({x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15}, 4)

    List.to_tuple(for i <- 0..15, do: elem(state, i) + elem(input, i) &&& 0xFFFFFFFF)
  end

  defp rounds(s, 0), do: s

  defp rounds({x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15}, n) do
    x4 = bxor(x4, rotl(x0 + x12, 7))
    x8 = bxor(x8, rotl(x4 + x0, 9))
    x12 = bxor(x12, rotl(x8 + x4, 13))
    x0 = bxor(x0, rotl(x12 + x8, 18))
    x9 = bxor(x9, rotl(x5 + x1, 7))
    x13 = bxor(x13, rotl(x9 + x5, 9))
    x1 = bxor(x1, rotl(x13 + x9, 13))
    x5 = bxor(x5, rotl(x1 + x13, 18))
    x14 = bxor(x14, rotl(x10 + x6, 7))
    x2 = bxor(x2, rotl(x14 + x10, 9))
    x6 = bxor(x6, rotl(x2 + x14, 13))
    x10 = bxor(x10, rotl(x6 + x2, 18))
    x3 = bxor(x3, rotl(x15 + x11, 7))
    x7 = bxor(x7, rotl(x3 + x15, 9))
    x11 = bxor(x11, rotl(x7 + x3, 13))
    x15 = bxor(x15, rotl(x11 + x7, 18))
    x1 = bxor(x1, rotl(x0 + x3, 7))
    x2 = bxor(x2, rotl(x1 + x0, 9))
    x3 = bxor(x3, rotl(x2 + x1, 13))
    x0 = bxor(x0, rotl(x3 + x2, 18))
    x6 = bxor(x6, rotl(x5 + x4, 7))
    x7 = bxor(x7, rotl(x6 + x5, 9))
    x4 = bxor(x4, rotl(x7 + x6, 13))
    x5 = bxor(x5, rotl(x4 + x7, 18))
    x11 = bxor(x11, rotl(x10 + x9, 7))
    x8 = bxor(x8, rotl(x11 + x10, 9))
    x9 = bxor(x9, rotl(x8 + x11, 13))
    x10 = bxor(x10, rotl(x9 + x8, 18))
    x12 = bxor(x12, rotl(x15 + x14, 7))
    x13 = bxor(x13, rotl(x12 + x15, 9))
    x14 = bxor(x14, rotl(x13 + x12, 13))
    x15 = bxor(x15, rotl(x14 + x13, 18))
    rounds({x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15}, n - 1)
  end

  defp rotl(v, c) do
    v = v &&& 0xFFFFFFFF
    (v <<< c ||| v >>> (32 - c)) &&& 0xFFFFFFFF
  end

  # Sealed text: two-factor secrets

  defp seal_key(secret), do: sha256("totp:" <> secret)

  @doc """
  Seals text with AES-256-GCM under a key from the secret, as "iv.body.tag"
  in base64url, the form the standalone server has always stored two-factor
  secrets in.
  """
  @spec seal_text(String.t(), String.t(), binary() | nil) :: String.t()
  def seal_text(text, secret, iv \\ nil) do
    iv = iv || random_bytes(12)
    {body, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, seal_key(secret), iv, text, "", true)
    "#{base64url(iv)}.#{base64url(body)}.#{base64url(tag)}"
  end

  @doc "The sealed text, or nil when it cannot be opened."
  @spec unseal_text(String.t(), String.t()) :: String.t() | nil
  def unseal_text(sealed, secret) do
    with [iv, body, tag | _] when iv != "" and tag != "" <- String.split(sealed, "."),
         iv when is_binary(iv) <- from_base64url(iv),
         body when is_binary(body) <- from_base64url(body),
         tag when is_binary(tag) <- from_base64url(tag),
         joined = body <> tag,
         true <- byte_size(iv) >= 12 and byte_size(joined) >= 16,
         cipher = binary_part(joined, 0, byte_size(joined) - 16),
         tag = binary_part(joined, byte_size(joined) - 16, 16),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, seal_key(secret), iv, cipher, "", tag, false) do
      Runlight.JS.decode_utf8(plain)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Saved keys: the mail service's, the assistant's, and connected installs' tokens

  defp mail_key(secret), do: sha256("runlight-mail:" <> secret)

  @doc "`v1:<iv>:<ciphertext>` in base64, or `plain:<value>` when the server has no secret to encrypt with."
  @spec seal(String.t(), String.t() | nil) :: String.t()
  def seal(value, secret) when secret in [nil, ""], do: "plain:" <> value

  def seal(value, secret) do
    iv = random_bytes(12)
    {body, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, mail_key(secret), iv, value, "", true)
    "v1:#{Base.encode64(iv)}:#{Base.encode64(body <> tag)}"
  end

  @doc "The sealed value, or nil when it cannot be opened (a different secret, or damaged)."
  @spec unseal(String.t(), String.t() | nil) :: String.t() | nil
  def unseal("plain:" <> value, _secret), do: value

  def unseal(sealed, secret) do
    with false <- secret in [nil, ""],
         ["v1", iv, data | _] when iv != "" and data != "" <- String.split(sealed, ":"),
         {:ok, iv} <- Base.decode64(iv),
         {:ok, data} <- Base.decode64(data),
         true <- byte_size(data) >= 16 and byte_size(iv) > 0 do
      body = binary_part(data, 0, byte_size(data) - 16)
      tag = binary_part(data, byte_size(data) - 16, 16)

      case :crypto.crypto_one_time_aead(:aes_256_gcm, mail_key(secret), iv, body, "", tag, false) do
        plain when is_binary(plain) -> Runlight.JS.decode_utf8(plain)
        _ -> nil
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Two-factor

  @base32 ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

  @doc "Base32 without padding, as authenticator apps read it."
  @spec base32(binary()) :: String.t()
  def base32(bytes) do
    {out, bits, value} =
      for <<byte <- bytes>>, reduce: {[], 0, 0} do
        {out, bits, value} ->
          value = value <<< 8 ||| byte
          bits = bits + 8
          emit(out, bits, value)
      end

    out = if bits > 0, do: [Enum.at(@base32, value <<< (5 - bits) &&& 31) | out], else: out
    out |> Enum.reverse() |> List.to_string()
  end

  defp emit(out, bits, value) when bits >= 5,
    do: emit([Enum.at(@base32, value >>> (bits - 5) &&& 31) | out], bits - 5, value &&& (1 <<< (bits - 5)) - 1)

  defp emit(out, bits, value), do: {out, bits, value}

  @doc "The bytes of base32 text; letters it does not know are skipped."
  @spec unbase32(String.t()) :: binary()
  def unbase32(text) do
    {out, _, _} =
      text
      |> String.replace(~r/=+\z/, "")
      |> String.upcase()
      |> String.to_charlist()
      |> Enum.reduce({[], 0, 0}, fn c, {out, bits, value} ->
        case Enum.find_index(@base32, &(&1 == c)) do
          nil ->
            {out, bits, value}

          i ->
            value = (value <<< 5 ||| i) &&& 0xFFFFFFFF
            bits = bits + 5

            if bits >= 8,
              do: {[value >>> (bits - 8) &&& 255 | out], bits - 8, value},
              else: {out, bits, value}
        end
      end)

    out |> Enum.reverse() |> :erlang.list_to_binary()
  end

  @doc "The six-digit code for a secret at a time step (RFC 6238: SHA-1, six digits)."
  @spec totp(String.t(), integer()) :: String.t()
  def totp(secret, step) do
    step = if is_float(step), do: trunc(step), else: step
    key = unbase32(secret)
    # WebCrypto refuses an HMAC key of no bytes.
    if key == "", do: raise(ArgumentError, "Zero-length key is not supported")
    mac = hmac(:sha, key, <<step::unsigned-big-64>>)
    at = :binary.last(mac) &&& 15
    <<_::binary-size(^at), n::unsigned-big-32, _::binary>> = mac
    n = n &&& 0x7FFFFFFF
    n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  @doc "The address an authenticator app reads from the QR code."
  @spec otpauth_uri(String.t(), String.t(), String.t()) :: String.t()
  def otpauth_uri(secret, email, host) do
    label = Runlight.JS.encode_uri_component("Runlight (#{host}):#{email}")
    issuer = Runlight.JS.encode_uri_component("Runlight (#{host})")
    "otpauth://totp/#{label}?secret=#{secret}&issuer=#{issuer}&algorithm=SHA1&digits=6&period=30"
  end
end
