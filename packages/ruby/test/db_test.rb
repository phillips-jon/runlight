# frozen_string_literal: true

require "test_helper"

# The database layer on each database the tests reach: values written as literals and read back, quoted
# names, transactions that join, and the lock that creating tables takes.
class DbTest < Minitest::Test
  def each_db
    Databases.kinds.each do |kind|
      yield Databases.db(kind), kind
    ensure
      Databases.cleanup
    end
  end

  def test_values_round_trip
    each_db do |db, kind|
      db.run('CREATE TABLE rl_probe ("key" VARCHAR(64) PRIMARY KEY, n BIGINT, f DOUBLE PRECISION, t TEXT)')
      text = "it's a \\ back\"slash ? and café \u{1F600}"
      db.run('INSERT INTO rl_probe ("key", n, f, t) VALUES (?, ?, ?, ?)', ["a", 9_007_199_254_740_991, 0.1, text])
      db.run('INSERT INTO rl_probe ("key", n, f, t) VALUES (?, ?, ?, ?)', ["b", nil, 2.0, "x"])
      rows = db.all('SELECT "key", n, f, t FROM rl_probe WHERE "key" = ? AND t <> \'?\'', ["a"])
      assert_equal 1, rows.length, kind
      assert_equal 9_007_199_254_740_991, Integer(rows[0]["n"]), kind
      assert_in_delta 0.1, Float(rows[0]["f"]), 0, kind
      assert_equal text, rows[0]["t"], kind
      assert_equal 1, db.affected('UPDATE rl_probe SET n = ? WHERE "key" = ?', [1, "b"]) if kind != "sqlite" && kind != "postgres"
      assert_equal [], db.all('DELETE FROM rl_probe WHERE "key" = ?', ["zzz"])
    end
  end

  def test_transactions_join_and_roll_back
    each_db do |db, kind|
      db.run("CREATE TABLE rl_probe (n BIGINT)")
      assert_raises(RuntimeError) do
        db.transaction do |outer|
          outer.run("INSERT INTO rl_probe (n) VALUES (?)", [1])
          outer.transaction { |inner| inner.run("INSERT INTO rl_probe (n) VALUES (?)", [2]) }
          raise "undo"
        end
      end
      assert_equal 0, Integer(db.all("SELECT COUNT(*) AS c FROM rl_probe")[0]["c"]), kind
      db.transaction { |t| t.run("INSERT INTO rl_probe (n) VALUES (?)", [3]) }
      assert_equal 1, Integer(db.all("SELECT COUNT(*) AS c FROM rl_probe")[0]["c"]), kind
      assert_equal 7, db.exclusive { |d| d.all("SELECT 7 AS seven")[0]["seven"].to_i }
    end
  end

  def test_mysql_text
    assert_equal "SELECT `key` FROM t WHERE a = 'it\\'s' AND b = 'x\\\\y' AND c = 1.5",
                 Runlight::Db::Database.mysql_text("SELECT \"key\" FROM t WHERE a = ? AND b = 'x\\y' AND c = ?", ["it's", 1.5])
  end
end
