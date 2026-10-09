# frozen_string_literal: true

require "securerandom"

module Runlight
  module Mail
    # A small SMTP client: implicit TLS (465), STARTTLS (587), or plain (local
    # relays), with AUTH PLAIN, over a TCP socket.
    module Smtp
      # Each reply must come within this long.
      REPLY_TIMEOUT_MS = 20_000
      private_constant :REPLY_TIMEOUT_MS

      module_function

      def encode_word(text)
        text.match?(/\A[\x20-\x7e]*\z/) ? text : "=?UTF-8?B?#{[text].pack("m0")}?="
      end

      # Base64 in lines of 76, each ending in CRLF, as `.replace(/.{1,76}/g, "$&\r\n")` writes it.
      def wrap(text)
        text.scan(/.{1,76}/).map { |line| "#{line}\r\n" }.join
      end

      # The message as MIME: text and HTML alternatives, both base64. Public for its test.
      #
      # now: milliseconds; the clock when nil. uuid: anything with call, standing in for crypto.randomUUID() in tests.
      def mime(m, from, now = nil, uuid = nil)
        uuid ||= -> { SecureRandom.uuid }
        now ||= (Time.now.to_r * 1000).floor
        boundary = "rl-#{uuid.call}"
        domain = m["from"].to_s.split("@", -1)[1] || "runlight.local"
        named = from.match(/\A(.*)<(.+)>\z/)
        from_header = named ? "#{encode_word(Transports.trim(named[1]))} <#{named[2]}>" : from
        headers = [
          "From: #{from_header}",
          "To: #{m["to"]}",
          "Subject: #{encode_word(m["subject"].to_s)}",
          # Date's toUTCString(), with +0000 for GMT.
          "Date: #{Time.at(now.floor.div(1000)).utc.strftime("%a, %d %b %Y %H:%M:%S")} +0000",
          "Message-ID: <#{uuid.call}@#{domain}>",
          "MIME-Version: 1.0",
        ]
        (m["headers"] || {}).each { |k, v| headers << "#{k}: #{v.to_s.delete("\r\n")}" }
        headers << "Content-Type: multipart/alternative; boundary=\"#{boundary}\""
        [
          headers.join("\r\n"),
          "",
          "--#{boundary}",
          "Content-Type: text/plain; charset=utf-8",
          "Content-Transfer-Encoding: base64",
          "",
          wrap([m["text"].to_s].pack("m0")),
          "--#{boundary}",
          "Content-Type: text/html; charset=utf-8",
          "Content-Transfer-Encoding: base64",
          "",
          wrap([m["html"].to_s].pack("m0")),
          "--#{boundary}--",
          "",
        ].join("\r\n")
      end

      # Sends one message. Each reply must come within 20 s, and the whole send
      # within the deadline (60 s), so a server that trickles a line now and then
      # cannot hold the scheduled check that sends reports. Its deadline is a
      # parameter for its test, as are the clock and UUIDs the MIME is written with.
      def deliver(config, m, from, deadline = 60_000, now = nil, uuid = nil)
        host = Transports.trim(config["host"].to_s)
        security = config["security"].to_s.empty? ? "starttls" : config["security"]
        port = port_number(config["port"].to_s)
        port = port.nan? || port.zero? ? (security == "tls" ? 465 : 587) : port.to_i
        late = "SMTP: #{host}:#{port} took longer than #{(deadline / 1000.0 + 0.5).floor} s"
        session = SmtpSession.new(host, port, monotonic + (deadline * 1_000_000), late)
        begin
          converse(session, config, m, from, security, now, uuid)
        ensure
          session.close
        end
      end

      def converse(s, config, m, from, security, now, uuid)
        s.connect(security == "tls", REPLY_TIMEOUT_MS)
        expect = lambda do |codes, what|
          reply = s.next_reply(REPLY_TIMEOUT_MS)
          raise MailError, Transports.slice16("SMTP #{what}: #{reply["code"]} #{reply["text"]}", 300) unless codes.include?(reply["code"])

          reply
        end
        expect.call([220], "greeting")
        name = (from.split("@", -1)[1] || "").sub(/>\z/, "")
        name = "localhost" if name.empty?
        s.write("EHLO #{name}")
        ehlo = expect.call([250], "EHLO")
        if security == "starttls"
          raise MailError.new("SMTP: the server does not offer STARTTLS; pick tls or none", "smtp_starttls", {}) unless ehlo["text"].match?(/STARTTLS/i)

          s.write("STARTTLS")
          expect.call([220], "STARTTLS")
          s.start_tls
          s.write("EHLO #{name}")
          expect.call([250], "EHLO")
        end
        unless config["username"].to_s.empty?
          s.write("AUTH PLAIN #{["\0#{config["username"]}\0#{config["password"]}"].pack("m0")}")
          expect.call([235], "sign-in")
        end
        s.write("MAIL FROM:<#{m["from"]}>")
        expect.call([250], "MAIL FROM")
        s.write("RCPT TO:<#{m["to"]}>")
        expect.call([250, 251], "RCPT TO")
        s.write("DATA")
        expect.call([354], "DATA")
        # A line starting with a dot gets a second one, so it is not read as the end.
        s.write_raw("#{mime(m, from, now, uuid).gsub("\r\n.", "\r\n..")}\r\n.\r\n")
        expect.call([250], "message")
        s.write("QUIT")
        # Wait for the goodbye, but never fail a sent message over it.
        begin
          s.next_reply(2000, true)
        rescue MailError => e
          raise e if e.code == "mail_slow"
        end
      end

      # JavaScript's Number() for the port as typed: NaN for anything that is not a number, and 0o, 0b, and
      # Infinity read as JavaScript reads them.
      def port_number(text)
        Js.number(text.to_s).to_f
      end

      # Nanoseconds on a clock that only goes forward, as hrtime() gives.
      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      end

      private_class_method :encode_word, :wrap, :converse
    end
  end
end
