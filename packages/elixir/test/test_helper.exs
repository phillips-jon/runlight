# The fixtures are made with TZ=UTC, so the tests refuse to run in any other
# zone. The `test` alias in mix.exs sets it.
if System.get_env("TZ") != "UTC" do
  IO.puts(:stderr, "run the tests with TZ=UTC (mix test sets it through its alias)")
  System.halt(1)
end

ExUnit.start(assert_receive_timeout: 2_000)
