# frozen_string_literal: true

module Runlight
  module Accounts
    # Counts failed sign-ins under a key and refuses more than a few in a while.
    # Keys are hashed with a key made on first use, so the counts never hold an
    # address or an email as it was given.
    #
    # TypeScript keeps the counts in its process. Here they live in the database's
    # settings, as "throttle:<name>:<id>" holding {count, until}, and the hashing
    # key as "throttle-key", so every process of an install shares the same counts.
    class Throttle
      KEY = "throttle-key"
      private_constant :KEY

      def initialize(store, name, limit = 10, window_ms = 15 * 60_000)
        @store = store
        @name = name
        @limit = limit
        @window_ms = window_ms
      end

      def blocked(key, now)
        blocked_id?(id(key), now)
      end

      # Counts a try before the slow check it guards, so a burst that arrives
      # while earlier tries are still being checked cannot get past the limit.
      # False, counting nothing, when the key is already at its limit. A try
      # that turns out right is taken back with forgive().
      def take(key, now)
        id = id(key)
        return false if blocked_id?(id, now)

        count(id, now)
        true
      end

      # Takes back one counted try, for one that turned out right.
      def forgive(key)
        id = id(key)
        entry = entry(id)
        return unless entry && entry["count"].positive?

        entry["count"] -= 1
        save(id, entry)
      end

      def record_failure(key, now)
        count(id(key), now)
      end

      def clear(key)
        @store.set_setting("#{prefix}#{id(key)}", nil)
      end

      private

      def salt
        saved = @store.setting(KEY)
        return saved if saved && saved != ""

        made = Hashing.random_id(16)
        @store.set_setting(KEY, made)
        made
      end

      def id(key)
        Crypto.base64url(Crypto.hmac("SHA-256", salt, key))[0, 22]
      end

      def prefix
        "throttle:#{@name}:"
      end

      def entry(id)
        saved = @store.setting("#{prefix}#{id}")
        entry = saved.nil? ? nil : Json.try_decode(saved)
        entry.is_a?(Hash) ? { "count" => int(entry["count"]), "until" => int(entry["until"]) } : nil
      end

      # A saved number, whole, and 0 for anything that is not a number.
      def int(value)
        n = Js.number(value.nil? ? 0 : value)
        n.is_a?(Float) && !n.finite? ? 0 : n.to_i
      end

      def save(id, entry)
        @store.set_setting("#{prefix}#{id}", Json.encode(entry))
      end

      def blocked_id?(id, now)
        entry = entry(id)
        return false if entry.nil? || entry["until"] <= now

        entry["count"] >= @limit
      end

      def count(id, now)
        entry = entry(id)
        if entry.nil? || entry["until"] <= now
          save(id, { "count" => 1, "until" => now + @window_ms })
          prune(now)
          return
        end
        entry["count"] += 1
        save(id, entry)
      end

      # Expired entries go first, then the oldest that are not blocked, and blocked ones last, so the counts
      # have a hard ceiling and a flood of made-up names cannot wipe out a real block. Run when a new entry is
      # made, since only then can there be more.
      def prune(now)
        entries = []
        @store.settings_starting_with(prefix).each do |row|
          entry = Json.try_decode(row["value"])
          until_ms = entry.is_a?(Hash) ? int(entry["until"]) : 0
          if until_ms <= now
            @store.set_setting(row["key"], nil)
            next
          end
          entries << { "key" => row["key"], "until" => until_ms, "blocked" => entry.is_a?(Hash) && int(entry["count"]) >= @limit }
        end
        size = entries.length
        return if size <= Accounts::MAX_THROTTLED

        # Oldest first: each entry's window started windowMs before its end.
        entries = entries.each_with_index.sort_by { |e, i| [e["until"], i] }.map(&:first)
        [false, true].each do |blocked|
          entries.each do |e|
            return if size <= Accounts::MAX_THROTTLED

            if e["blocked"] == blocked
              @store.set_setting(e["key"], nil)
              size -= 1
            end
          end
        end
      end
    end
  end
end
