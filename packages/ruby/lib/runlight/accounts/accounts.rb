# frozen_string_literal: true

module Runlight
  module Accounts
    # Accounts: who may sign in, their password hashes, two-factor, invites, and the signed cookie that keeps them
    # signed in. The standalone server always has them, and an app turns them on with routes(accounts: true).
    #
    # The owner can do everything, and nobody else can remove them or change their role; they can hand ownership to an
    # admin. An admin can do everything the owner can apart from that. A member changes sites, goals, links, and the
    # rest, but not people, the mail service, the assistant's settings, or deleting a site. A viewer reads every site's
    # stats and changes nothing.
    #
    # A user is a Hash with the TypeScript User's keys: id, email, hash, role ("owner", "admin", "member", or
    # "viewer"), createdAt, twoFactor (whether sign-in also asks for a code), and recoveryLeft (recovery codes not
    # yet used). An invite has id, email, role, invitedBy, createdAt, and expiresAt.
    class Accounts
      SESSION_COOKIE = "runlight_session"
      # Thirty days, renewed on every sign-in.
      SESSION_MS = 30 * 86_400_000
      MIN_PASSWORD = 10
      # The most sign-in keys the throttle remembers at once.
      MAX_THROTTLED = 10_000
      # How long an invite link works.
      INVITE_MS = 7 * 86_400_000

      ROLES = %w[owner admin member viewer].freeze

      # What passes for an email address, with JavaScript's \s.
      EMAIL = /\A[^#{Js::SPACE}@<>"]+@[^#{Js::SPACE}@<>"]+\.[^#{Js::SPACE}@<>"]+\z/
      private_constant :EMAIL

      # A password checked against nothing, so a wrong email takes as long as a wrong password. Made when first needed.
      @decoy = nil

      class << self
        attr_accessor :decoy
      end

      def initialize(store, secret)
        @store = store
        @secret = secret
        @ready = false
      end

      # A stored role read back; anything unknown reads as a viewer, the least it could be.
      def self.role_from(value)
        ROLES.include?(value) ? value : "viewer"
      end

      # Starts turning on two-factor: a new secret, kept aside until a code from it is confirmed.
      def start_two_factor(id)
        init
        secret = Crypto.base32(Crypto.random_bytes(20))
        @store.db.run("UPDATE rl_users SET totp_pending = ? WHERE id = ?", [seal(secret), id])
        secret
      end

      # Turns two-factor on once a code from the new secret checks out, and returns ten recovery codes, shown once.
      def confirm_two_factor(id, code, now)
        init
        row = @store.db.all("SELECT totp_pending FROM rl_users WHERE id = ?", [id])[0]
        secret = !row.nil? && Js.truthy?(row["totp_pending"]) ? unseal(row["totp_pending"].to_s) : nil
        step = !secret.nil? && secret != "" ? Crypto.match_step(secret, code, now, -1) : nil
        return nil if step.nil?

        recovery = Crypto.recovery_codes
        # The code that turned it on is not marked used, so signing in again at once with it works.
        @store.db.run("UPDATE rl_users SET totp_secret = ?, totp_pending = NULL, totp_recovery = ?, totp_step = NULL WHERE id = ?", [
          seal(secret),
          Json.encode(recovery.map { |c| Crypto.recovery_hash(c) }),
          id,
        ])
        recovery
      end

      # New recovery codes in place of the old ones.
      def new_recovery_codes(id)
        init
        recovery = Crypto.recovery_codes
        @store.db.run("UPDATE rl_users SET totp_recovery = ? WHERE id = ?", [Json.encode(recovery.map { |c| Crypto.recovery_hash(c) }), id])
        recovery
      end

      # Drops a set-up left half done, after too many wrong codes, so it must start again with the password.
      def cancel_two_factor_setup(id)
        init
        @store.db.run("UPDATE rl_users SET totp_pending = NULL WHERE id = ?", [id])
      end

      def disable_two_factor(id)
        init
        @store.db.run("UPDATE rl_users SET totp_secret = NULL, totp_pending = NULL, totp_recovery = NULL, totp_step = NULL WHERE id = ?", [id])
      end

      # Checks a six-digit code, or a recovery code, for an account with two-factor on.
      # A code works once: one already used, or older, is refused, and a recovery code is crossed off.
      # One check at a time, so two sign-ins at once cannot both use the same code: TypeScript queues them per
      # account in its process, and here the database's lock is taken, which holds across processes too.
      def check_second_factor(id, code, now)
        init
        turn { check_second_factor_now(id, code, now) }
      end

      # A short-lived ticket naming an account whose password checked out and
      # which still owes a code. Signed like a session, so it cannot be made up.
      def pending_for(user, now)
        ticket("pending", user, now + (5 * 60_000))
      end

      # A ticket that looks and acts like pending_for's, except that no code ever
      # passes with it. A wrong password gets one once an account with
      # two-factor has had too many, so the answer never tells a right password.
      def decoy_for(user, now)
        ticket("decoy", user, now + (5 * 60_000))
      end

      # The account a code-step ticket names, and whether a right code may sign in with it:
      # {"user" => user, "real" => bool}, or nil.
      def from_pending(value, now)
        user = from_ticket("pending", value, now)
        return { "user" => user, "real" => true } unless user.nil?

        decoy = from_ticket("decoy", value, now)
        decoy.nil? ? nil : { "user" => decoy, "real" => false }
      end

      # A ticket for a sign-in link sent by email, for fifteen minutes. A new password withdraws it.
      def link_for(user, now)
        ticket("link", user, now + (15 * 60_000))
      end

      # The account a sign-in link is for. A link works once: using it withdraws it, and every link sent
      # before it. Uses take turns, so a link opened twice at once lets one in.
      def from_link(value, now)
        user = from_ticket("link", value, now)
        return nil if user.nil?

        expires = Js.number(value.split(".", -1)[1] || "")
        turn do
          key = "login-link-used:#{user["id"]}"
          next nil if expires <= Js.number(@store.setting(key) || 0)

          @store.set_setting(key, Js.string(expires))
          user
        end
      end

      def count
        init
        row = @store.db.all("SELECT COUNT(*) AS n FROM rl_users")[0]
        row.nil? ? 0 : Js.number(row["n"] || 0).to_i
      end

      def by_email(email)
        init
        found = @store.db.all("SELECT * FROM rl_users WHERE email = ?", [Js.lower(Js.trim(email))])[0]
        found.nil? ? nil : row(found)
      end

      def by_id(id)
        init
        found = @store.db.all("SELECT * FROM rl_users WHERE id = ?", [id])[0]
        found.nil? ? nil : row(found)
      end

      def list
        init
        @store.db.all("SELECT * FROM rl_users ORDER BY created_at, id").map { |r| row(r) }
      end

      # Changes a role. The owner's never changes here, and nobody becomes the owner here: see hand_over().
      def set_role(id, role)
        # The tables first: making them takes the same lock as a turn.
        init
        turn do
          user = find(id)
          raise AccountError.new("Unknown account", "unknown_account") if user.nil?
          if user["role"] == "owner"
            raise AccountError.new("Only the owner can change their own role, by handing ownership to an admin", "owner_protected")
          end
          raise AccountError.new("Ownership is handed over by the owner", "owner_hand_over") if role == "owner"

          @store.db.run("UPDATE rl_users SET role = ? WHERE id = ?", [role, id])
          user["role"] = role
          user
        end
      end

      # Makes an admin the owner, and the owner an admin.
      def hand_over(from, to)
        init
        turn do
          owner = find(from)
          nxt = find(to)
          raise AccountError.new("Only the owner can hand over ownership", "owner_hand_over") if owner.nil? || owner["role"] != "owner"
          raise AccountError.new("Unknown account", "unknown_account") if nxt.nil?
          raise AccountError.new("Make them an admin first", "owner_needs_admin") if nxt["role"] != "admin"

          @store.db.run("UPDATE rl_users SET role = 'owner' WHERE id = ?", [to])
          @store.db.run("UPDATE rl_users SET role = 'admin' WHERE id = ?", [from])
        end
        nil
      end

      # Removes an account. The owner cannot be removed.
      def remove(id)
        # The tables first: making them takes the same lock as a turn.
        init
        turn do
          user = find(id)
          raise AccountError.new("Unknown account", "unknown_account") if user.nil?
          raise AccountError.new("The owner cannot be removed", "owner_protected") if user["role"] == "owner"

          @store.db.run("DELETE FROM rl_users WHERE id = ?", [id])
          @store.set_setting("login-link-used:#{id}", nil)
        end
        nil
      end

      # Makes an account, or sets a new password on an existing one. A new account is the owner when it is the first,
      # and otherwise an admin unless a role is given, since a server has one owner.
      def set_password(email, password, now, role = nil)
        init
        address = Js.lower(Js.trim(email))
        raise AccountError.new("Enter an email address", "email_invalid") unless address.match?(EMAIL)
        if Js.length(password) < MIN_PASSWORD
          raise AccountError.new("Use a password of at least #{MIN_PASSWORD} characters", "password_short", { "min" => MIN_PASSWORD.to_s })
        end

        hash = Crypto.hash_password(password)
        existing = by_email(address)
        unless existing.nil?
          @store.db.run("UPDATE rl_users SET hash = ? WHERE id = ?", [hash, existing["id"]])
          existing["hash"] = hash
          return existing
        end
        first = count.zero?
        given = role || (first ? "owner" : "admin")
        user = {
          "id" => Crypto.hex(Crypto.random_bytes(12)),
          "email" => address,
          "hash" => hash,
          "role" => given == "owner" && !first ? "admin" : given,
          "createdAt" => now,
          "twoFactor" => false,
          "recoveryLeft" => 0,
        }
        @store.db.run("INSERT INTO rl_users (id, email, hash, role, created_at) VALUES (?, ?, ?, ?, ?)",
                      [user["id"], user["email"], user["hash"], user["role"], user["createdAt"]])
        user
      end

      # Invites that still work, newest first. Expired ones are cleared on the way.
      def invites(now)
        init
        @store.db.run("DELETE FROM rl_invites WHERE expires_at <= ?", [now])
        @store.db.all("SELECT * FROM rl_invites ORDER BY created_at DESC, id").map { |r| invite_row(r) }
      end

      # Invites someone to join with a role, and returns {"invite" => ..., "code" => ...}, the code for their link.
      # Asking again replaces the earlier invite, so only the newest link works.
      def invite(email, role, invited_by, now)
        init
        turn { invite_now(email, role, invited_by, now) }
      end

      # The invite a link's code belongs to, while it still works.
      def invite_by_code(code, now)
        init
        return nil unless code.match?(/\A[A-Za-z0-9_-]{20,64}\z/)

        row = @store.db.all("SELECT * FROM rl_invites WHERE code_hash = ? AND expires_at > ?", [self.class.code_hash(code), now])[0]
        row.nil? ? nil : invite_row(row)
      end

      def cancel_invite(id)
        init
        before = @store.db.all("SELECT id FROM rl_invites WHERE id = ?", [id]).length
        @store.db.run("DELETE FROM rl_invites WHERE id = ?", [id])
        before.positive?
      end

      # Turns an invite into an account with the password its person chose. The link then stops working.
      def accept_invite(code, password, now)
        invite = invite_by_code(code, now)
        raise AccountError.new("This invite has expired or was already used. Ask for a new one.", "invite_gone") if invite.nil?
        unless by_email(invite["email"]).nil?
          raise AccountError.new("#{invite["email"]} already has an account", "account_exists", { "email" => invite["email"] })
        end

        user = set_password(invite["email"], password, now, invite["role"])
        @store.db.run("DELETE FROM rl_invites WHERE id = ?", [invite["id"]])
        user
      end

      # The account for an email and password, or nil. Takes the same time either way.
      def sign_in(email, password)
        user = by_email(email)
        if user.nil?
          Crypto.check_password(password, self.class.decoy ||= Crypto.hash_password(Crypto.hex(Crypto.random_bytes(16))))
          return nil
        end
        Crypto.check_password(password, user["hash"]) ? user : nil
      end

      # A cookie value naming the user and when it expires, signed with the
      # server's secret and the user's password hash, so changing a password
      # signs out every other browser.
      def session_for(user, now)
        expires = now + SESSION_MS
        body = "#{user["id"]}.#{expires}"
        "#{body}.#{sign(body, session_key(user))}"
      end

      # The signed-in user for a cookie value, or nil.
      def from_session(value, now)
        parts = value.split(".", -1)
        id = parts[0] || ""
        expires = parts[1] || ""
        signature = parts[2] || ""
        return nil if id == "" || expires == "" || signature == "" || !(Js.number(expires) > now)

        user = by_id(id)
        return nil if user.nil?

        Crypto.same_text(sign("#{id}.#{expires}", session_key(user)), signature) ? user : nil
      end

      # A long-lived mark for a browser that signed in to an account. With it, failed tries by others
      # against that account cannot lock this browser out; the per-address limit still applies.
      # A new password withdraws it.
      def device_for(user)
        "#{user["id"]}.#{sign("device.#{user["id"]}", user["hash"])}"
      end

      def trusts_device(value, user)
        parts = value.split(".", -1)
        id = parts[0] || ""
        signature = parts[1] || ""
        return false if id != user["id"] || signature == ""

        Crypto.same_text(sign("device.#{user["id"]}", user["hash"]), signature)
      end

      def self.code_hash(code)
        Crypto.hex(Crypto.sha256(code))
      end

      private

      # Changes to who has an account take turns: on Postgres and MySQL across processes, through the database's
      # lock, so two owners demoting each other at once cannot leave none, and a double-clicked invite makes one.
      def turn(&fn)
        @store.db.exclusive { fn.call }
      end

      def init
        return if @ready

        # Several processes starting at once create the tables one at a time.
        @store.db.exclusive do
          db = @store.db
          # MySQL keys TEXT only by a prefix, so there the keyed columns are VARCHAR, in the binary collation the store's tables use.
          my = db.dialect == "mysql"
          str = ->(n) { my ? "VARCHAR(#{n})" : "TEXT" }
          table = my ? " DEFAULT CHARSET=utf8mb4 COLLATE=#{Store::Sql::MYSQL_COLLATION}" : ""
          db.run("CREATE TABLE IF NOT EXISTS rl_users (id #{str.call(100)} PRIMARY KEY, email #{str.call(320)} NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)#{table}")
          # Roles came later; a table from before them gains the column, and its accounts stay owners.
          columns = if db.dialect == "sqlite"
                      db.all("PRAGMA table_info(rl_users)")
                    else
                      db.all("SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'rl_users' AND table_schema = #{my ? "DATABASE()" : "current_schema()"}")
                    end
          names = columns.map { |c| (c["name"] || c["NAME"] || "").to_s }
          db.run("ALTER TABLE rl_users ADD COLUMN role #{str.call(20)} NOT NULL DEFAULT 'owner'") unless names.include?("role")
          # Two-factor came later still: the secret (sealed), one being set up, recovery code hashes, and the last code's step.
          [%w[totp_secret TEXT], %w[totp_pending TEXT], %w[totp_recovery TEXT], %w[totp_step BIGINT]].each do |name, type|
            db.run("ALTER TABLE rl_users ADD COLUMN #{name} #{type}") unless names.include?(name)
          end
          db.run(
            "CREATE TABLE IF NOT EXISTS rl_invites (id #{str.call(100)} PRIMARY KEY, email #{str.call(320)} NOT NULL UNIQUE, role #{str.call(20)} NOT NULL, " \
            "code_hash #{str.call(128)} NOT NULL UNIQUE, invited_by #{str.call(100)} NOT NULL, created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL)#{table}",
          )
          # A server has one owner. One from before, with several, keeps the first and the rest become admins,
          # who can still do everything but remove the owner. Invites to join as an owner become invites as an admin.
          owners = db.all("SELECT id FROM rl_users WHERE role = 'owner' ORDER BY created_at, id")
          owners.drop(1).each { |extra| db.run("UPDATE rl_users SET role = 'admin' WHERE id = ?", [extra["id"].to_s]) }
          db.run("UPDATE rl_invites SET role = 'admin' WHERE role = 'owner'")
        end
        @ready = true
      end

      def row(r)
        recovery = Js.truthy?(r["totp_recovery"]) ? Json.decode(r["totp_recovery"].to_s) : []
        {
          "id" => r["id"].to_s,
          "email" => r["email"].to_s,
          "hash" => r["hash"].to_s,
          "role" => self.class.role_from(r["role"]),
          "createdAt" => Js.number(r["created_at"]),
          "twoFactor" => Js.truthy?(r["totp_secret"]),
          "recoveryLeft" => recovery.length,
        }
      end

      # Seals a two-factor secret with the install's secret, so the database alone cannot make codes.
      def seal(text)
        Crypto.seal_text(text, @secret)
      end

      def unseal(sealed)
        Crypto.unseal_text(sealed, @secret)
      end

      def check_second_factor_now(id, code, now)
        row = @store.db.all("SELECT totp_secret, totp_recovery, totp_step FROM rl_users WHERE id = ?", [id])[0]
        return false if row.nil? || !Js.truthy?(row["totp_secret"])

        given = Js.trim(code)
        digits = given.gsub(/[#{Js::SPACE}]/o, "")
        if digits.match?(/\A\d{6}\z/)
          secret = unseal(row["totp_secret"].to_s)
          after = row["totp_step"].nil? ? -1 : Js.number(row["totp_step"]).to_i
          step = !secret.nil? && secret != "" ? Crypto.match_step(secret, digits, now, after) : nil
          return false if step.nil?

          @store.db.run("UPDATE rl_users SET totp_step = ? WHERE id = ?", [step, id])
          return true
        end
        hashes = Js.truthy?(row["totp_recovery"]) ? Json.decode(row["totp_recovery"].to_s) : []
        at = hashes.index(Crypto.recovery_hash(given))
        return false if at.nil?

        hashes.delete_at(at)
        @store.db.run("UPDATE rl_users SET totp_recovery = ? WHERE id = ?", [Json.encode(hashes), id])
        true
      end

      def ticket(kind, user, expires)
        body = "#{user["id"]}.#{expires}"
        "#{body}.#{sign("#{kind}.#{body}", user["hash"])}"
      end

      def from_ticket(kind, value, now)
        parts = value.split(".", -1)
        id = parts[0] || ""
        expires = parts[1] || ""
        signature = parts[2] || ""
        return nil if id == "" || expires == "" || signature == "" || !(Js.number(expires) > now)

        user = by_id(id)
        return nil if user.nil?

        Crypto.same_text(sign("#{kind}.#{id}.#{expires}", user["hash"]), signature) ? user : nil
      end

      def find(id)
        list.find { |user| user["id"] == id }
      end

      def invite_row(r)
        {
          "id" => r["id"].to_s,
          "email" => r["email"].to_s,
          "role" => self.class.role_from(r["role"]),
          "invitedBy" => r["invited_by"].to_s,
          "createdAt" => Js.number(r["created_at"]),
          "expiresAt" => Js.number(r["expires_at"]),
        }
      end

      def invite_now(email, role, invited_by, now)
        address = Js.lower(Js.trim(email))
        raise AccountError.new("Enter an email address", "email_invalid") unless address.match?(EMAIL)
        raise AccountError.new("#{address} already has an account", "account_exists", { "email" => address }) unless by_email(address).nil?

        code = Crypto.base64url(Crypto.random_bytes(24))
        invite = { "id" => Crypto.hex(Crypto.random_bytes(12)), "email" => address, "role" => role, "invitedBy" => invited_by, "createdAt" => now,
                   "expiresAt" => now + INVITE_MS }
        @store.db.run("DELETE FROM rl_invites WHERE email = ?", [address])
        @store.db.run("INSERT INTO rl_invites (id, email, role, code_hash, invited_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)", [
          invite["id"],
          invite["email"],
          invite["role"],
          self.class.code_hash(code),
          invite["invitedBy"],
          invite["createdAt"],
          invite["expiresAt"],
        ])
        { "invite" => invite, "code" => code }
      end

      # What a session is signed with: the password hash, and whether two-factor is on, so changing either ends other sessions.
      def session_key(user)
        "#{user["hash"]}#{user["twoFactor"] ? ".2fa" : ""}"
      end

      def sign(body, hash)
        Crypto.signature(@secret, body, hash)
      end
    end
  end
end
