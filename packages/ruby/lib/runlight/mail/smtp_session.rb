# frozen_string_literal: true

require "openssl"
require "socket"

module Runlight
  module Mail
    # One SMTP connection for Smtp.send: the socket, the replies read from it
    # (multi-line included, one at a time), and the whole send's deadline, which
    # every wait is held to.
    class SmtpSession
      # deadline: nanoseconds on Smtp.monotonic's clock.
      def initialize(host, port, deadline, late_message)
        @host = host
        @port = port
        @deadline = deadline
        @late_message = late_message
        @socket = nil
        @buffer = "".b
        @lines = []
      end

      def connect(tls, timeout_ms)
        wait = [timeout_ms, left].min
        raise late if wait <= 0

        begin
          socket = Socket.tcp(@host, @port, connect_timeout: wait / 1000.0)
        rescue SystemCallError, SocketError, IO::TimeoutError => e
          raise late if left <= 0

          detail = connect_detail(e, wait >= timeout_ms)
          raise MailError.new("SMTP: could not connect to #{@host}:#{@port}: #{detail}", "mail_unreachable",
                              { "host" => "#{@host}:#{@port}", "detail" => detail })
        end
        @socket = socket
        return unless tls

        begin
          handshake
        rescue MailError
          raise
        rescue OpenSSL::SSL::SSLError, SystemCallError, IOError => e
          raise late if left <= 0

          close
          detail = e.message
          raise MailError.new("SMTP: could not connect to #{@host}:#{@port}: #{detail}", "mail_unreachable",
                              { "host" => "#{@host}:#{@port}", "detail" => detail })
        end
      end

      def write(line)
        write_raw("#{line}\r\n")
      end

      def write_raw(data)
        data = data.b
        until data.empty?
          raise MailError, "SMTP: the server closed the connection" if @socket.nil?

          wait = left
          raise late if wait <= 0

          begin
            sent = @socket.write_nonblock(data, exception: false)
          rescue SystemCallError, IOError, OpenSSL::SSL::SSLError
            raise late if left <= 0

            raise MailError, "SMTP: the server closed the connection"
          end
          if sent == :wait_writable || sent == :wait_readable
            ready = sent == :wait_writable ? IO.select(nil, [@socket], nil, wait / 1000.0) : IO.select([@socket], nil, nil, wait / 1000.0)
            raise late if ready.nil? && left <= 0

            next
          end
          if sent.nil? || sent.zero?
            raise late if left <= 0

            raise MailError, "SMTP: the server closed the connection"
          end
          data = data.byteslice(sent, data.bytesize - sent)
        end
      end

      # The next whole reply, as {"code" => Integer, "text" => String}. Raises when none comes within
      # `timeout_ms` (or, with `quiet`, gives nil then), and a mail_slow error once the deadline passes.
      def next_reply(timeout_ms, quiet = false)
        idle_until = Smtp.monotonic + (timeout_ms * 1_000_000)
        loop do
          while (at = @buffer.index("\r\n"))
            line = @buffer.byteslice(0, at)
            @buffer = @buffer.byteslice(at + 2, @buffer.bytesize - at - 2)
            @lines << Js.scrub(line.byteslice(4, line.bytesize) || "")
            if line.byteslice(3, 1) != "-"
              head = line.byteslice(0, 3)
              reply = { "code" => head.match?(/\A\d+\z/) ? head.to_i : -1, "text" => @lines.join(" ") }
              @lines = []
              return reply
            end
            # Activity resets the idle timer, as Node's socket timeout does.
            idle_until = Smtp.monotonic + (timeout_ms * 1_000_000)
          end
          raise MailError, "SMTP: the server closed the connection" if @socket.nil?

          deadline_left = left
          raise late if deadline_left <= 0

          idle_left = (idle_until - Smtp.monotonic) / 1_000_000.0
          if idle_left <= 0
            return nil if quiet

            close
            raise MailError, "SMTP: timed out"
          end
          wait = [deadline_left, idle_left].min
          begin
            chunk = @socket.read_nonblock(8192, exception: false)
          rescue SystemCallError, IOError, OpenSSL::SSL::SSLError
            chunk = nil
          end
          if chunk == :wait_readable || chunk == :wait_writable
            # Nothing came in the time left; the checks above decide what that means.
            chunk == :wait_readable ? IO.select([@socket], nil, nil, wait / 1000.0) : IO.select(nil, [@socket], nil, wait / 1000.0)
            next
          end
          if chunk.nil?
            close
            raise MailError, "SMTP: the server closed the connection"
          end
          unless chunk.empty?
            @buffer << chunk.b
            idle_until = Smtp.monotonic + (timeout_ms * 1_000_000)
          end
        end
      end

      # Turns on TLS after STARTTLS. Anything the server sent before it is dropped, as a new reader would.
      def start_tls
        @buffer = "".b
        @lines = []
        raise late if left <= 0

        handshake
      rescue OpenSSL::SSL::SSLError, SystemCallError, IOError => e
        raise late if left <= 0

        raise MailError, "SMTP: TLS failed: #{e.message}"
      end

      def close
        return if @socket.nil?

        begin
          @socket.close
        rescue StandardError
          nil
        end
        @socket = nil
      end

      private

      def late
        close
        MailError.new(@late_message, "mail_slow", { "host" => "#{@host}:#{@port}" })
      end

      # Milliseconds left before the deadline.
      def left
        (@deadline - Smtp.monotonic) / 1_000_000.0
      end

      # Wraps the socket in TLS, checking the certificate and its name, within the time left.
      def handshake
        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true)
        ssl = OpenSSL::SSL::SSLSocket.new(@socket, context)
        ssl.hostname = @host
        ssl.sync_close = true
        loop do
          result = ssl.connect_nonblock(exception: false)
          break if result == ssl

          wait = left
          raise late if wait <= 0

          ready = result == :wait_readable ? IO.select([@socket], nil, nil, wait / 1000.0) : IO.select(nil, [@socket], nil, wait / 1000.0)
          raise late if ready.nil? && left <= 0
        end
        @socket = ssl
      end

      def connect_detail(error, whole_wait)
        return(whole_wait ? "timed out" : "connection failed") if error.is_a?(IO::TimeoutError) || error.is_a?(Errno::ETIMEDOUT)

        text = error.message.sub(/ - .*\z/m, "")
        text.empty? ? "connection failed" : text
      end
    end
  end
end
