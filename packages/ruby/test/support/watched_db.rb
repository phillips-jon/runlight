# frozen_string_literal: true

# A database that lets a test see, and step into, every statement: as the TypeScript tests replace db.run and
# db.all on a store. Statements inside a transaction or lock go through it too.
class WatchedDb
  # Called with (sql, params) before each statement.
  attr_accessor :before
  # Called with (sql, params) after each run.
  attr_accessor :after_run
  attr_reader :inner

  def initialize(inner)
    @inner = inner
    @before = nil
    @after_run = nil
  end

  def dialect
    @inner.dialect
  end

  def all(sql, params = [])
    @before&.call(sql, params)
    @inner.all(sql, params)
  end

  def run(sql, params = [])
    @before&.call(sql, params)
    @inner.run(sql, params)
    @after_run&.call(sql, params)
    nil
  end

  def affected(sql, params = [])
    @before&.call(sql, params)
    @inner.affected(sql, params)
  end

  def transaction
    @inner.transaction { yield self }
  end

  def exclusive
    @inner.exclusive { yield self }
  end

  def close
    @inner.close
  end
end
