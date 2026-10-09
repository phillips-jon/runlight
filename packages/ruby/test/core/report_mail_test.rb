# frozen_string_literal: true

require "test_helper"
require "stringio"

# The mail service's settings and the reports sent through it, as mail.test.ts and audit.test.ts test them without routes.
class CoreReportMailTest < Minitest::Test
  Json = Runlight::Json
  Response = Runlight::Http::Response

  def setup
    # A failed send is logged, as TS logs it; the test reads the result instead.
    @stderr = $stderr
    $stderr = StringIO.new
    @status = 200
    @fetcher = FakeFetcher.new { Response.new(@status == 200 ? "{}" : "nope", status: @status) }
  end

  def teardown
    $stderr = @stderr
    super
  end

  def runlight(clock, options = {})
    Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "now" => clock, "fetcher" => @fetcher }.merge(options))
  end

  # A report as the routes add one: a period already due counts as sent.
  def add_report(rl, email, frequency, lang = "en", origin = "https://stats.example.com/runlight")
    site = rl.site("default")
    due = Runlight::Reports.last_period(frequency, rl.now, site["timezone"])
    rl.store.insert_report({
      "id" => Runlight::Hashing.random_id, "site" => "default", "email" => email, "frequency" => frequency, "lang" => lang,
      "token" => Runlight::Hashing.random_id(16), "origin" => origin, "lastPeriod" => rl.now >= due["dueAt"] ? due["key"] : "",
      "lastSentAt" => nil, "createdAt" => rl.now,
    })
  end

  def mail_error(&block)
    assert_raises(Runlight::Mail::MailError, &block)
  end

  def test_reports_go_out_once_per_period_retry_after_a_failure_and_keep_keys_from_the_browser
    now = Time.utc(2026, 10, 8, 15).to_i * 1000
    rl = runlight(-> { now }, { "site" => { "name" => "Example", "hostnames" => ["example.com"], "timezone" => "America/Toronto" }, "secret" => "s3cret" })
    rl.init

    bad_from = mail_error { rl.save_mail_settings({ "service" => "resend", "apiKey" => "re_live_key", "from" => "not an address" }) }
    assert_equal "mail_from", bad_from.code, "a code the dashboard says in its own language"
    assert_equal({}, bad_from.params)
    no_key = mail_error { rl.save_mail_settings({ "service" => "resend", "apiKey" => "", "from" => "reports@example.com" }) }
    assert_equal ["mail_field", { "field" => "apiKey" }], [no_key.code, no_key.params]
    assert_equal "mail_service", mail_error { rl.save_mail_settings({ "service" => "pigeon" }) }.code
    rl.save_mail_settings({ "service" => "resend", "apiKey" => "re_live_key", "from" => "reports@example.com", "fromName" => "Runlight" })
    stored = rl.store.setting("mail").to_s
    assert stored.start_with?("v1:")
    refute_includes stored, "re_live_key", "the key is encrypted at rest"
    assert_equal({ "service" => "resend", "apiKey" => "re_live_key", "from" => "reports@example.com", "fromName" => "Runlight", "source" => "dashboard" }, rl.mail_settings)
    # Saving again with the key left blank keeps it.
    rl.save_mail_settings({ "service" => "resend", "apiKey" => "", "from" => "reports@example.com" })
    assert_equal "re_live_key", rl.mail_settings["apiKey"]

    add_report(rl, "jon@example.com", "weekly", "fr")
    assert_equal({ "sent" => 0, "failed" => 0 }, rl.send_reports, "a report added on a Wednesday waits for the next Monday")
    assert_equal 0, @fetcher.requests.length
    now += 7 * 86_400_000
    @status = 500
    assert_equal({ "sent" => 0, "failed" => 1 }, rl.send_reports)
    @status = 200
    @fetcher.requests.clear
    assert_equal({ "sent" => 1, "failed" => 0 }, rl.send_reports, "a failed send is tried again")
    body = Json.decode(@fetcher.requests[0]["body"])
    assert_equal "https://api.resend.com/emails", @fetcher.requests[0]["url"]
    assert_equal "jon@example.com", body["to"][0]
    assert_equal "Example : 0 personne la semaine dernière", body["subject"]
    assert_includes body["html"], "du 5 oct. au 11 oct. 2026"
    assert_includes body["html"], "0 personne a visité le site la semaine dernière.", "French counts zero as one"
    assert_match %r{\A<https://stats\.example\.com/runlight/unsubscribe/[a-f0-9]{32}>\z}, body["headers"]["List-Unsubscribe"]
    assert_equal "List-Unsubscribe=One-Click", body["headers"]["List-Unsubscribe-Post"]
    assert_includes body["text"], "https://stats.example.com/runlight/?site=default"
    assert_equal({ "sent" => 0, "failed" => 0 }, rl.send_reports, "the same period never goes twice")
    now += 7 * 86_400_000
    assert_equal({ "sent" => 1, "failed" => 0 }, rl.send_reports, "the next week does")
    assert_equal({ "ok" => true, "reports" => { "sent" => 0, "failed" => 0 } }, rl.check)
  end

  def test_a_report_added_before_mondays_8am_still_gets_last_weeks
    # Monday 5 October 2026, 7:00 in Toronto: last week is over and not yet due.
    now = Time.utc(2026, 10, 5, 11).to_i * 1000
    rl = runlight(-> { now }, { "site" => { "name" => "Example", "hostnames" => ["example.com"], "timezone" => "America/Toronto" } })
    rl.save_mail_settings({ "service" => "resend", "apiKey" => "re_1", "from" => "reports@example.com" })
    add_report(rl, "jon@example.com", "weekly")
    add_report(rl, "jon@example.com", "monthly")
    assert_equal({ "sent" => 0, "failed" => 0 }, rl.send_reports)
    now += 2 * 3_600_000
    assert_equal({ "sent" => 1, "failed" => 0 }, rl.send_reports)
    assert_includes Json.decode(@fetcher.requests[0]["body"])["subject"], "last week"
  end

  def test_no_mail_service_sends_nothing_and_saying_so_is_an_error
    now = Time.utc(2026, 10, 12, 15).to_i * 1000
    rl = runlight(-> { now })
    rl.init
    add_report(rl, "jon@example.com", "weekly")
    rl.store.db.run("UPDATE rl_reports SET last_period = ''")
    assert_equal({ "sent" => 0, "failed" => 0 }, rl.send_reports)
    assert_equal "mail_unset", mail_error { rl.send_mail({ "to" => "a@b.co", "subject" => "s", "html" => "h", "text" => "t" }) }.code
  end

  def test_a_mail_service_in_code_is_shown_and_cannot_be_changed
    rl = runlight(-> { 0 }, { "mail" => { "service" => "resend", "apiKey" => "re_code", "from" => "r@example.com" } })
    assert_equal({ "service" => "resend", "apiKey" => "re_code", "from" => "r@example.com", "source" => "code" }, rl.mail_settings)
    assert_equal "mail_in_code", mail_error { rl.save_mail_settings(nil) }.code
    rl.send_mail({ "to" => "jon@example.com", "subject" => "Hi", "html" => "<p>Hi</p>", "text" => "Hi" })
    assert_equal "r@example.com", Json.decode(@fetcher.requests[0]["body"])["from"]
  end

  def test_a_saved_smtp_password_is_kept_only_while_the_server_it_goes_to_stays_the_same
    rl = runlight(-> { 0 }, { "secret" => "k" * 32 })
    base = { "service" => "smtp", "host" => "smtp.example.com", "port" => "587", "security" => "starttls", "username" => "me", "from" => "r@example.com" }
    rl.save_mail_settings(base.merge("password" => "hunter2-long"))
    rl.save_mail_settings(base.merge("password" => "", "from" => "reports@example.com"))
    assert_equal "hunter2-long", rl.mail_settings["password"], "same server, blank field: kept"
    rl.save_mail_settings(base.merge("host" => "evil.example", "password" => "", "from" => "reports@example.com"))
    assert_equal "", rl.mail_settings["password"] || "", "a new host needs the password typed again"
    rl.save_mail_settings(nil)
    assert_nil rl.mail_settings
  end

  def test_a_key_sealed_with_another_secret_reads_as_no_mail_service
    store = Runlight::Stores.sqlite(":memory:")
    one = Runlight::Core.new({ "store" => store, "secret" => "one" })
    one.save_mail_settings({ "service" => "resend", "apiKey" => "re_1", "from" => "r@example.com" })
    two = Runlight::Core.new({ "store" => store, "secret" => "two" })
    assert_nil two.mail_settings
  end
end
