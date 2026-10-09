defmodule Runlight.Accounts do
  @moduledoc """
  Accounts: who may sign in, their password hashes, two-factor, invites, and
  the signed cookie that keeps them signed in (the SDK's accounts/auth.ts).
  An app turns them on with `Runlight.routes(rl, accounts: true)`.

  The owner can do everything, and nobody else can remove them or change their
  role; they can hand ownership to an admin. An admin can do everything the
  owner can apart from that. A member changes sites, goals, links, and the
  rest, but not people, the mail service, the assistant's settings, or
  deleting a site. A viewer reads every site's stats and changes nothing.

  A user is a JavaScript object: id, email, hash, role, createdAt,
  twoFactor, and recoveryLeft.
  """

  alias Runlight.AccountError
  alias Runlight.Crypto
  alias Runlight.Db
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.State
  alias Runlight.Store
  alias Runlight.Store.Sql

  defstruct [:rl, :store, :secret]

  @type t :: %__MODULE__{}

  @doc "The session cookie's name."
  def session_cookie, do: "runlight_session"

  @doc "Thirty days, renewed on every sign-in."
  def session_ms, do: 30 * 86_400_000

  @doc "The shortest password taken."
  def min_password, do: 10

  @doc "How long an invite link works."
  def invite_ms, do: 7 * 86_400_000

  @roles ["owner", "admin", "member", "viewer"]
  @step_ms 30_000

  @doc "Accounts in an instance's database, signing with `secret`."
  @spec new(Runlight.t(), String.t()) :: t()
  def new(%Runlight{} = rl, secret), do: %__MODULE__{rl: rl, store: rl.store, secret: secret}

  # A stored role read back; anything unknown reads as a viewer, the least it could be.
  defp role_from(value), do: if(value in @roles, do: value, else: "viewer")

  defp db(acc), do: acc.store.db
  defp all(acc, sql, params \\ []), do: Db.all(db(acc), sql, params)
  defp run(acc, sql, params \\ []), do: Db.run(db(acc), sql, params)
  defp first(acc, sql, params), do: acc |> all(sql, params) |> List.first()
  defp dialect(acc), do: Db.dialect(db(acc))

  @dialyzer {:nowarn_function, refuse: 2}
  defp refuse(message, code, params \\ []), do: raise(AccountError, message: message, code: code, params: params)

  # Changes to who has an account take turns, in this process and, on Postgres and MySQL, across processes, so two
  # owners demoting each other at once cannot leave none, and a double-clicked invite makes one.
  defp turn(acc, fun) do
    State.one_at_a_time(acc.rl.table, :accounts_turn, fn -> Db.exclusive(db(acc), fn _ -> fun.() end) end)
  end

  @doc false
  def init(acc) do
    table = acc.rl.table

    unless State.get(table, :accounts_ready) do
      State.one_at_a_time(table, :accounts_init, fn ->
        unless State.get(table, :accounts_ready) do
          # Several processes starting at once create the tables one at a time.
          Db.exclusive(db(acc), fn _ -> create(acc) end)
          State.put(table, :accounts_ready, true)
        end
      end)
    end

    :ok
  end

  defp create(acc) do
    # MySQL keys TEXT only by a prefix, so there the keyed columns are VARCHAR, in the binary collation the store's
    # tables use.
    my = dialect(acc) == "mysql"
    str = fn n -> if my, do: "VARCHAR(#{n})", else: "TEXT" end
    table = if my, do: " DEFAULT CHARSET=utf8mb4 COLLATE=#{Sql.mysql_collation()}", else: ""

    run(
      acc,
      "CREATE TABLE IF NOT EXISTS rl_users (id #{str.(100)} PRIMARY KEY, email #{str.(320)} NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)#{table}"
    )

    # Roles came later; a table from before them gains the column, and its accounts stay owners.
    columns =
      if dialect(acc) == "sqlite",
        do: all(acc, "PRAGMA table_info(rl_users)"),
        else:
          all(
            acc,
            "SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'rl_users' AND table_schema = #{if my, do: "DATABASE()", else: "current_schema()"}"
          )

    names = Enum.map(columns, &JS.string(&1["name"] || &1["NAME"] || &1["COLUMN_NAME"]))
    unless "role" in names, do: run(acc, "ALTER TABLE rl_users ADD COLUMN role #{str.(20)} NOT NULL DEFAULT 'owner'")

    # Two-factor came later still: the secret (sealed), one being set up, recovery code hashes, and the last code's
    # step.
    for {name, type} <- [
          {"totp_secret", "TEXT"},
          {"totp_pending", "TEXT"},
          {"totp_recovery", "TEXT"},
          {"totp_step", "BIGINT"}
        ],
        name not in names do
      run(acc, "ALTER TABLE rl_users ADD COLUMN #{name} #{type}")
    end

    run(
      acc,
      "CREATE TABLE IF NOT EXISTS rl_invites (id #{str.(100)} PRIMARY KEY, email #{str.(320)} NOT NULL UNIQUE, role #{str.(20)} NOT NULL, code_hash #{str.(128)} NOT NULL UNIQUE, invited_by #{str.(100)} NOT NULL, created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL)#{table}"
    )

    # A server has one owner. One from before, with several, keeps the first and the rest become admins. Invites to
    # join as an owner become invites as an admin.
    owners = all(acc, "SELECT id FROM rl_users WHERE role = 'owner' ORDER BY created_at, id")

    for extra <- Enum.drop(owners, 1),
        do: run(acc, "UPDATE rl_users SET role = 'admin' WHERE id = ?", [JS.string(extra["id"])])

    run(acc, "UPDATE rl_invites SET role = 'admin' WHERE role = 'owner'")
  end

  defp row(r) do
    recovery =
      case r["totp_recovery"] do
        v when v in [nil, ""] -> []
        v -> JS.parse!(JS.string(v))
      end

    JS.obj(
      id: JS.string(r["id"]),
      email: JS.string(r["email"]),
      hash: JS.string(r["hash"]),
      role: role_from(r["role"]),
      createdAt: JS.number(r["created_at"]),
      twoFactor: JS.truthy?(r["totp_secret"]),
      recoveryLeft: length(recovery)
    )
  end

  # Two-factor: TOTP as authenticator apps expect it (RFC 6238): SHA-1, six digits, 30 seconds.

  # Ten one-use recovery codes, like "k7dq-2mfa".
  defp recovery_codes do
    for _ <- 1..10 do
      raw = 5 |> Crypto.random_bytes() |> Crypto.base32() |> String.downcase()
      "#{binary_part(raw, 0, 4)}-#{binary_part(raw, 4, 4)}"
    end
  end

  @doc false
  def recovery_hash(code),
    do: code |> String.replace(~r/[^a-z0-9]/i, "") |> JS.lower() |> Crypto.sha256() |> Crypto.hex()

  defp code_hash(code), do: code |> Crypto.sha256() |> Crypto.hex()

  @doc "Starts turning on two-factor: a new secret, kept aside until a code from it is confirmed."
  def start_two_factor(acc, id) do
    init(acc)
    secret = Crypto.base32(Crypto.random_bytes(20))
    run(acc, "UPDATE rl_users SET totp_pending = ? WHERE id = ?", [Crypto.seal_text(secret, acc.secret), id])
    secret
  end

  @doc "Turns two-factor on once a code from the new secret checks out, and returns ten recovery codes, shown once."
  def confirm_two_factor(acc, id, code, now) do
    init(acc)
    r = first(acc, "SELECT totp_pending FROM rl_users WHERE id = ?", [id])
    secret = if r && JS.truthy?(r["totp_pending"]), do: Crypto.unseal_text(JS.string(r["totp_pending"]), acc.secret)
    step = if secret, do: match_step(secret, code, now, -1)

    if step == nil do
      nil
    else
      recovery = recovery_codes()
      # The code that turned it on is not marked used, so signing in again at once with it works.
      run(
        acc,
        "UPDATE rl_users SET totp_secret = ?, totp_pending = NULL, totp_recovery = ?, totp_step = NULL WHERE id = ?",
        [
          Crypto.seal_text(secret, acc.secret),
          JS.stringify(Enum.map(recovery, &recovery_hash/1)),
          id
        ]
      )

      recovery
    end
  end

  @doc "New recovery codes in place of the old ones."
  def new_recovery_codes(acc, id) do
    init(acc)
    recovery = recovery_codes()

    run(acc, "UPDATE rl_users SET totp_recovery = ? WHERE id = ?", [
      JS.stringify(Enum.map(recovery, &recovery_hash/1)),
      id
    ])

    recovery
  end

  @doc "Drops a set-up left half done, after too many wrong codes, so it must start again with the password."
  def cancel_two_factor_setup(acc, id) do
    init(acc)
    run(acc, "UPDATE rl_users SET totp_pending = NULL WHERE id = ?", [id])
  end

  def disable_two_factor(acc, id) do
    init(acc)

    run(
      acc,
      "UPDATE rl_users SET totp_secret = NULL, totp_pending = NULL, totp_recovery = NULL, totp_step = NULL WHERE id = ?",
      [id]
    )
  end

  @doc """
  Checks a six-digit code, or a recovery code, for an account with two-factor
  on. A code works once: one already used, or older, is refused, and a
  recovery code is crossed off. One check at a time per account.
  """
  def check_second_factor(acc, id, code, now) do
    State.one_at_a_time(acc.rl.table, {:second_factor, id}, fn -> check_second_factor_now(acc, id, code, now) end)
  end

  defp check_second_factor_now(acc, id, code, now) do
    init(acc)
    r = first(acc, "SELECT totp_secret, totp_recovery, totp_step FROM rl_users WHERE id = ?", [id])

    if r == nil or not JS.truthy?(r["totp_secret"]) do
      false
    else
      given = JS.trim(code)
      digits = String.replace(given, ~r/\s/u, "")

      if Regex.match?(~r/\A\d{6}\z/, digits) do
        secret = Crypto.unseal_text(JS.string(r["totp_secret"]), acc.secret)
        after_step = if r["totp_step"] == nil, do: -1, else: JS.number(r["totp_step"])
        step = if secret, do: match_step(secret, digits, now, after_step)

        if step == nil do
          false
        else
          run(acc, "UPDATE rl_users SET totp_step = ? WHERE id = ?", [step, id])
          true
        end
      else
        hashes = if JS.truthy?(r["totp_recovery"]), do: JS.parse!(JS.string(r["totp_recovery"])), else: []
        hash = recovery_hash(given)

        case Enum.find_index(hashes, &(&1 == hash)) do
          nil ->
            false

          at ->
            run(acc, "UPDATE rl_users SET totp_recovery = ? WHERE id = ?", [
              JS.stringify(List.delete_at(hashes, at)),
              id
            ])

            true
        end
      end
    end
  end

  # The time step a code matches, one step either side for clocks that drift, newer than `after`; else nil.
  @doc false
  def match_step(secret, code, now, after_step) do
    current = Integer.floor_div(now, @step_ms)

    Enum.find([current, current - 1, current + 1], fn step ->
      step > after_step and Crypto.totp(secret, step) == code
    end)
  end

  @doc "A short-lived ticket naming an account whose password checked out and which still owes a code."
  def pending_for(acc, user, now), do: ticket(acc, "pending", user, now + 5 * 60_000)

  @doc "A ticket like pending_for's, except that no code ever passes with it."
  def decoy_for(acc, user, now), do: ticket(acc, "decoy", user, now + 5 * 60_000)

  @doc "The account a code-step ticket names, and whether a right code may sign in with it."
  def from_pending(acc, value, now) do
    case from_ticket(acc, "pending", value, now) do
      nil ->
        case from_ticket(acc, "decoy", value, now) do
          nil -> nil
          user -> %{user: user, real: false}
        end

      user ->
        %{user: user, real: true}
    end
  end

  @doc "A ticket for a sign-in link sent by email, for fifteen minutes. A new password withdraws it."
  def link_for(acc, user, now), do: ticket(acc, "link", user, now + 15 * 60_000)

  @doc """
  The account a sign-in link is for. A link works once: using it withdraws it,
  and every link sent before it.
  """
  def from_link(acc, value, now) do
    case from_ticket(acc, "link", value, now) do
      nil ->
        nil

      user ->
        expires = value |> String.split(".") |> Enum.at(1) |> JS.number()

        turn(acc, fn ->
          key = "login-link-used:#{user["id"]}"

          if expires <= JS.number(Store.setting(acc.store, key) || 0) do
            nil
          else
            Store.set_setting(acc.store, key, JS.string(expires))
            user
          end
        end)
    end
  end

  defp ticket(acc, kind, user, expires) do
    body = "#{user["id"]}.#{expires}"
    "#{body}.#{sign(acc, "#{kind}.#{body}", user["hash"])}"
  end

  defp from_ticket(acc, kind, value, now) do
    case String.split(value, ".") do
      [id, expires, signature | _] when id != "" and expires != "" and signature != "" ->
        n = JS.number(expires)

        if is_number(n) and n > now do
          case by_id(acc, id) do
            nil -> nil
            user -> if Crypto.same_text?(sign(acc, "#{kind}.#{id}.#{expires}", user["hash"]), signature), do: user
          end
        end

      _ ->
        nil
    end
  end

  def count(acc) do
    init(acc)
    r = first(acc, "SELECT COUNT(*) AS n FROM rl_users", [])
    JS.number(JS.nullish(r && r["n"], 0))
  end

  def by_email(acc, email) do
    init(acc)
    r = first(acc, "SELECT * FROM rl_users WHERE email = ?", [email |> JS.trim() |> JS.lower()])
    r && row(r)
  end

  def by_id(acc, id) do
    init(acc)
    r = first(acc, "SELECT * FROM rl_users WHERE id = ?", [id])
    r && row(r)
  end

  def list(acc) do
    init(acc)
    acc |> all("SELECT * FROM rl_users ORDER BY created_at, id") |> Enum.map(&row/1)
  end

  @doc "Changes a role. The owner's never changes here, and nobody becomes the owner here: see hand_over/3."
  def set_role(acc, id, role) do
    init(acc)

    turn(acc, fn ->
      user = Enum.find(list(acc), &(&1["id"] == id)) || refuse("Unknown account", "unknown_account")

      if user["role"] == "owner",
        do: refuse("Only the owner can change their own role, by handing ownership to an admin", "owner_protected")

      if role == "owner", do: refuse("Ownership is handed over by the owner", "owner_hand_over")
      run(acc, "UPDATE rl_users SET role = ? WHERE id = ?", [role, id])
      Object.put(user, "role", role)
    end)
  end

  @doc "Makes an admin the owner, and the owner an admin."
  def hand_over(acc, from, to) do
    init(acc)

    turn(acc, fn ->
      users = list(acc)
      owner = Enum.find(users, &(&1["id"] == from))
      next = Enum.find(users, &(&1["id"] == to))

      if owner == nil or owner["role"] != "owner",
        do: refuse("Only the owner can hand over ownership", "owner_hand_over")

      if next == nil, do: refuse("Unknown account", "unknown_account")
      if next["role"] != "admin", do: refuse("Make them an admin first", "owner_needs_admin")
      run(acc, "UPDATE rl_users SET role = 'owner' WHERE id = ?", [to])
      run(acc, "UPDATE rl_users SET role = 'admin' WHERE id = ?", [from])
      :ok
    end)
  end

  @doc "Removes an account. The owner cannot be removed."
  def remove(acc, id) do
    init(acc)

    turn(acc, fn ->
      user = Enum.find(list(acc), &(&1["id"] == id)) || refuse("Unknown account", "unknown_account")
      if user["role"] == "owner", do: refuse("The owner cannot be removed", "owner_protected")
      run(acc, "DELETE FROM rl_users WHERE id = ?", [id])
      Store.set_setting(acc.store, "login-link-used:#{id}", nil)
      :ok
    end)
  end

  @doc """
  Makes an account, or sets a new password on an existing one. A new account
  is the owner when it is the first, and otherwise an admin unless a role is
  given, since a server has one owner.
  """
  def set_password(acc, email, password, now, role \\ nil) do
    init(acc)
    address = email |> JS.trim() |> JS.lower()
    unless Runlight.email?(address), do: refuse("Enter an email address", "email_invalid")

    if JS.len16(password) < min_password(),
      do: refuse("Use a password of at least #{min_password()} characters", "password_short", min: "#{min_password()}")

    hash = Crypto.hash_password(password)

    case by_email(acc, address) do
      %Object{} = existing ->
        run(acc, "UPDATE rl_users SET hash = ? WHERE id = ?", [hash, existing["id"]])
        Object.put(existing, "hash", hash)

      nil ->
        first = count(acc) == 0
        given = role || if(first, do: "owner", else: "admin")
        role = if given == "owner" and not first, do: "admin", else: given

        user =
          JS.obj(
            id: Crypto.hex(Crypto.random_bytes(12)),
            email: address,
            hash: hash,
            role: role,
            createdAt: now,
            twoFactor: false,
            recoveryLeft: 0
          )

        run(acc, "INSERT INTO rl_users (id, email, hash, role, created_at) VALUES (?, ?, ?, ?, ?)", [
          user["id"],
          user["email"],
          user["hash"],
          user["role"],
          user["createdAt"]
        ])

        user
    end
  end

  defp invite_row(r) do
    JS.obj(
      id: JS.string(r["id"]),
      email: JS.string(r["email"]),
      role: role_from(r["role"]),
      invitedBy: JS.string(r["invited_by"]),
      createdAt: JS.number(r["created_at"]),
      expiresAt: JS.number(r["expires_at"])
    )
  end

  @doc "Invites that still work, newest first. Expired ones are cleared on the way."
  def invites(acc, now) do
    init(acc)
    run(acc, "DELETE FROM rl_invites WHERE expires_at <= ?", [now])
    acc |> all("SELECT * FROM rl_invites ORDER BY created_at DESC, id") |> Enum.map(&invite_row/1)
  end

  @doc """
  Invites someone to join with a role, and returns the invite and the code for
  their link. Asking again replaces the earlier invite.
  """
  def invite(acc, email, role, invited_by, now) do
    init(acc)

    turn(acc, fn ->
      address = email |> JS.trim() |> JS.lower()
      unless Runlight.email?(address), do: refuse("Enter an email address", "email_invalid")
      if by_email(acc, address), do: refuse("#{address} already has an account", "account_exists", email: address)
      code = Crypto.base64url(Crypto.random_bytes(24))

      invite =
        JS.obj(
          id: Crypto.hex(Crypto.random_bytes(12)),
          email: address,
          role: role,
          invitedBy: invited_by,
          createdAt: now,
          expiresAt: now + invite_ms()
        )

      run(acc, "DELETE FROM rl_invites WHERE email = ?", [address])

      run(
        acc,
        "INSERT INTO rl_invites (id, email, role, code_hash, invited_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
          invite["id"],
          invite["email"],
          invite["role"],
          code_hash(code),
          invite["invitedBy"],
          invite["createdAt"],
          invite["expiresAt"]
        ]
      )

      %{invite: invite, code: code}
    end)
  end

  @doc "The invite a link's code belongs to, while it still works."
  def invite_by_code(acc, code, now) do
    init(acc)

    if Regex.match?(~r/\A[A-Za-z0-9_-]{20,64}\z/, code) do
      r = first(acc, "SELECT * FROM rl_invites WHERE code_hash = ? AND expires_at > ?", [code_hash(code), now])
      r && invite_row(r)
    end
  end

  def cancel_invite(acc, id) do
    init(acc)
    before = length(all(acc, "SELECT id FROM rl_invites WHERE id = ?", [id]))
    run(acc, "DELETE FROM rl_invites WHERE id = ?", [id])
    before > 0
  end

  @doc "Turns an invite into an account with the password its person chose. The link then stops working."
  def accept_invite(acc, code, password, now) do
    invite =
      invite_by_code(acc, code, now) ||
        refuse("This invite has expired or was already used. Ask for a new one.", "invite_gone")

    if by_email(acc, invite["email"]),
      do: refuse("#{invite["email"]} already has an account", "account_exists", email: invite["email"])

    user = set_password(acc, invite["email"], password, now, invite["role"])
    run(acc, "DELETE FROM rl_invites WHERE id = ?", [invite["id"]])
    user
  end

  @doc "The account for an email and password, or nil. Takes the same time either way."
  def sign_in(acc, email, password) do
    case by_email(acc, email) do
      nil ->
        Crypto.check_password(password, decoy(acc))
        nil

      user ->
        if Crypto.check_password(password, user["hash"]), do: user
    end
  end

  # A password checked against nothing, so a wrong email takes as long as a wrong password. Made when first needed.
  defp decoy(acc) do
    case State.get(acc.rl.table, :accounts_decoy) do
      nil -> State.put(acc.rl.table, :accounts_decoy, Crypto.hash_password(Crypto.hex(Crypto.random_bytes(16))))
      hash -> hash
    end
  end

  @doc """
  A cookie value naming the user and when it expires, signed with the
  server's secret and the user's password hash, so changing a password signs
  out every other browser.
  """
  def session_for(acc, user, now) do
    expires = now + session_ms()
    body = "#{user["id"]}.#{expires}"
    "#{body}.#{sign(acc, body, session_key(user))}"
  end

  @doc "The signed-in user for a cookie value, or nil."
  def from_session(acc, value, now) do
    case String.split(value, ".") do
      [id, expires, signature | _] when id != "" and expires != "" and signature != "" ->
        n = JS.number(expires)

        if is_number(n) and n > now do
          case by_id(acc, id) do
            nil -> nil
            user -> if Crypto.same_text?(sign(acc, "#{id}.#{expires}", session_key(user)), signature), do: user
          end
        end

      _ ->
        nil
    end
  end

  # What a session is signed with: the password hash, and whether two-factor is on.
  defp session_key(user), do: "#{user["hash"]}#{if user["twoFactor"], do: ".2fa", else: ""}"

  @doc "A long-lived mark for a browser that signed in to an account. A new password withdraws it."
  def device_for(acc, user), do: "#{user["id"]}.#{sign(acc, "device.#{user["id"]}", user["hash"])}"

  def trusts_device(acc, value, user) do
    case String.split(value, ".") do
      [id, signature | _] when signature != "" ->
        id == user["id"] and Crypto.same_text?(sign(acc, "device.#{user["id"]}", user["hash"]), signature)

      _ ->
        false
    end
  end

  defp sign(acc, body, hash), do: Crypto.base64url(Crypto.hmac(:sha256, acc.secret, "#{body}.#{hash}"))
end
