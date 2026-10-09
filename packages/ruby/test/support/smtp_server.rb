# frozen_string_literal: true

require "socket"

# A fake SMTP server for the mail tests, on a thread of its own. It listens on a free port, serves one
# connection at a time, and after each one queues what the client sent, read back with conversation().
#
# relay: answers as the TS tests' relay does (AUTH PLAIN checks jon/pw, no STARTTLS).
# trickle: sends "220-still here" every 100 ms and never finishes its greeting.
# refuse: sends "535 no" and closes at once.
class SmtpServer
  attr_reader :port

  def initialize(mode = "relay")
    @mode = mode
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @done = Queue.new
    @thread = Thread.new { serve }
    @thread.report_on_exception = false
  end

  # What the next finished connection received ("received", and "closed" for trickle), waiting up to
  # `seconds` for it.
  def conversation(seconds = 5)
    @done.pop(timeout: seconds)
  end

  def stop
    @thread.kill
    @thread.join(1)
    @server.close
  rescue IOError
    nil
  end

  private

  def serve
    loop do
      socket = @server.accept
      @done << case @mode
               when "trickle" then trickle(socket)
               when "refuse" then refuse(socket)
               else relay(socket)
               end
    end
  end

  def refuse(socket)
    socket.write("535 no\r\n")
    socket.close
    { "received" => "", "closed" => true }
  end

  def trickle(socket)
    received = +""
    loop do
      begin
        socket.write("220-still here\r\n")
      rescue SystemCallError, IOError
        break
      end
      sleep 0.1
      chunk = socket.read_nonblock(8192, exception: false)
      break if chunk.nil?

      received << chunk if chunk.is_a?(String)
    rescue SystemCallError, IOError
      break
    end
    socket.close
    { "received" => received, "closed" => true }
  end

  def relay(socket)
    received = "".b
    socket.write("220 test ESMTP\r\n")
    buffer = "".b
    in_data = false
    open = true
    while open
      chunk = begin
        socket.readpartial(8192)
      rescue EOFError, SystemCallError, IOError
        nil
      end
      break if chunk.nil?

      received << chunk
      buffer << chunk
      while (at = buffer.index("\r\n"))
        line = buffer.byteslice(0, at)
        buffer = buffer.byteslice(at + 2, buffer.bytesize - at - 2)
        if in_data
          if line == "."
            in_data = false
            socket.write("250 queued\r\n")
          end
          next
        end
        if line.start_with?("EHLO")
          socket.write("250-test\r\n250-SIZE 1000\r\n250 AUTH PLAIN\r\n")
        elsif line.start_with?("AUTH PLAIN")
          socket.write(line[11..].unpack1("m") == "\0jon\0pw" ? "235 ok\r\n" : "535 no\r\n")
        elsif line == "DATA"
          in_data = true
          socket.write("354 go\r\n")
        elsif line == "QUIT"
          socket.write("221 bye\r\n")
          open = false
          break
        else
          socket.write("250 ok\r\n")
        end
      end
    end
    # Whatever the client still sends before it hangs up.
    unless open
      while IO.select([socket], nil, nil, 1)
        chunk = socket.read_nonblock(8192, exception: false)
        break unless chunk.is_a?(String)

        received << chunk
      end
    end
    socket.close
    { "received" => received.force_encoding(Encoding::UTF_8) }
  end
end
