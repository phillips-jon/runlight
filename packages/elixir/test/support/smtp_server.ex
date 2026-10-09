defmodule Runlight.Test.SmtpServer do
  @moduledoc false
  # A fake SMTP server for the mail tests, as the TS tests' relay answers:
  # AUTH PLAIN checks jon/pw, and there is no STARTTLS. It serves one
  # connection at a time and sends the process that started it every byte
  # each client sent. In :trickle mode it sends "220-still here" every 100 ms
  # and never finishes its greeting.

  @doc "Starts a server; answers `{port, pid}`."
  def start(mode \\ :relay) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listen)
        send(parent, {:smtp_port, port})
        loop(listen, mode, parent)
      end)

    receive do
      {:smtp_port, port} -> {port, pid}
    end
  end

  @doc "What the next finished connection sent, as %{received, closed}, or nil."
  def conversation(timeout \\ 5000) do
    receive do
      {:smtp_conversation, c} -> c
    after
      timeout -> nil
    end
  end

  def stop(pid), do: Process.exit(pid, :kill)

  defp loop(listen, mode, parent) do
    {:ok, socket} = :gen_tcp.accept(listen)
    received = if mode == :trickle, do: trickle(socket, ""), else: relay(socket)
    :gen_tcp.close(socket)
    send(parent, {:smtp_conversation, received})
    loop(listen, mode, parent)
  end

  defp trickle(socket, received) do
    case :gen_tcp.send(socket, "220-still here\r\n") do
      :ok ->
        Process.sleep(100)

        case :gen_tcp.recv(socket, 0, 0) do
          {:ok, chunk} -> trickle(socket, received <> chunk)
          {:error, :timeout} -> trickle(socket, received)
          {:error, _} -> %{received: received, closed: true}
        end

      {:error, _} ->
        %{received: received, closed: true}
    end
  end

  defp relay(socket) do
    :gen_tcp.send(socket, "220 test ESMTP\r\n")
    serve(socket, "", "", false)
  end

  defp serve(socket, received, buffer, in_data) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, chunk} ->
        {buffer, in_data, open} = lines(socket, buffer <> chunk, in_data)
        received = received <> chunk
        if open, do: serve(socket, received, buffer, in_data), else: %{received: drain(socket, received)}

      {:error, _} ->
        %{received: received}
    end
  end

  defp drain(socket, received) do
    case :gen_tcp.recv(socket, 0, 300) do
      {:ok, chunk} -> drain(socket, received <> chunk)
      _ -> received
    end
  end

  defp lines(socket, buffer, in_data) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        cond do
          in_data ->
            if line == ".", do: :gen_tcp.send(socket, "250 queued\r\n")
            lines(socket, rest, line != ".")

          String.starts_with?(line, "EHLO") ->
            :gen_tcp.send(socket, "250-test\r\n250-SIZE 1000\r\n250 AUTH PLAIN\r\n")
            lines(socket, rest, false)

          String.starts_with?(line, "AUTH PLAIN") ->
            ok = Base.decode64(String.slice(line, 11..-1//1)) == {:ok, <<0, "jon", 0, "pw">>}
            :gen_tcp.send(socket, if(ok, do: "235 ok\r\n", else: "535 no\r\n"))
            lines(socket, rest, false)

          line == "DATA" ->
            :gen_tcp.send(socket, "354 go\r\n")
            lines(socket, rest, true)

          line == "QUIT" ->
            :gen_tcp.send(socket, "221 bye\r\n")
            {rest, false, false}

          true ->
            :gen_tcp.send(socket, "250 ok\r\n")
            lines(socket, rest, false)
        end

      [_] ->
        {buffer, in_data, true}
    end
  end
end
