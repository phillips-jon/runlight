defmodule Runlight.Hash do
  @moduledoc false
  # Internal. Hashes and random ids (the SDK's hash.ts).

  @doc "SHA-256 of text, as hex."
  @spec sha256(iodata()) :: String.t()
  def sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  @doc "HMAC-SHA-256 of text under key, as hex."
  @spec hmac(iodata(), iodata()) :: String.t()
  def hmac(key, text), do: :crypto.mac(:hmac, :sha256, key, text) |> Base.encode16(case: :lower)

  @doc """
  The day's visitor hash: SHA-256 of salt, site, IP, and user agent, cut to
  64 bits. The salt changes every day and old salts are deleted, so the hash
  cannot be recomputed and does not follow anyone across days.
  """
  @spec visitor_hash(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def visitor_hash(salt, site, ip, ua), do: binary_part(sha256("#{salt}\n#{site}\n#{ip}\n#{ua}"), 0, 16)

  @doc "A random id of `bytes` bytes, as hex."
  @spec random_id(pos_integer()) :: String.t()
  def random_id(bytes \\ 12), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)

  @doc "A new day's salt."
  @spec random_salt() :: String.t()
  def random_salt, do: random_id(32)
end
