defmodule Runlight.Mail.Smtp do
  @moduledoc false
  # Internal. A small SMTP client: implicit TLS (465), STARTTLS (587), or
  # plain (local relays), with AUTH PLAIN (the SDK's mail/smtp.ts).

  alias Runlight.MailError

  defp b64(text), do: Base.encode64(text)
  defp wrap(text), do: Regex.replace(~r/.{1,76}/, text, "\\0\r\n")
  defp encode_word(text), do: if(Regex.match?(~r/\A[\x20-\x7e]*\z/, text), do: text, else: "=?UTF-8?B?#{b64(text)}?=")

  @doc "A random UUID, version 4, as crypto.randomUUID() writes one."
  def uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u::128>> = <<a::48, 4::4, b::12, 2::2, c::62>>
    hex = u |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end

  @days ~w(Thu Fri Sat Sun Mon Tue Wed)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # Date.prototype.toUTCString, with GMT as +0000.
  defp date(now) do
    days = Integer.floor_div(now, 86_400_000)
    rest = Integer.mod(now, 86_400_000)
    {y, m, d} = Runlight.JS.civil_from_days(days)
    pad = &Runlight.JS.pad(&1, 2)
    hms = "#{pad.(div(rest, 3_600_000))}:#{pad.(rem(div(rest, 60_000), 60))}:#{pad.(rem(div(rest, 1000), 60))}"

    "#{Enum.at(@days, Integer.mod(days, 7))}, #{pad.(d)} #{Enum.at(@months, m - 1)} #{Runlight.JS.pad(y, 4)} #{hms} +0000"
  end

  @doc """
  The message as MIME: text and HTML alternatives, both base64. `now` is
  epoch milliseconds and `uuid` makes the boundary and the Message-ID.
  """
  @spec mime(map(), String.t(), integer(), (-> String.t())) :: String.t()
  def mime(m, from, now \\ System.os_time(:millisecond), uuid \\ &uuid/0) do
    boundary = "rl-#{uuid.()}"

    domain =
      case String.split(m.from, "@") do
        [_, d | _] -> d
        _ -> "runlight.local"
      end

    from_header =
      case Regex.run(~r/^(.*)<(.+)>$/, from) do
        [_, name, address] -> "#{encode_word(Runlight.JS.trim(name))} <#{address}>"
        nil -> from
      end

    headers =
      [
        "From: #{from_header}",
        "To: #{m.to}",
        "Subject: #{encode_word(m.subject)}",
        "Date: #{date(now)}",
        "Message-ID: <#{uuid.()}@#{domain}>",
        "MIME-Version: 1.0"
      ] ++
        Enum.map(Map.get(m, :headers) || [], fn {k, v} -> "#{k}: #{String.replace(v, ~r/[\r\n]/, "")}" end) ++
        [~s(Content-Type: multipart/alternative; boundary="#{boundary}")]

    Enum.join(
      [
        Enum.join(headers, "\r\n"),
        "",
        "--#{boundary}",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: base64",
        "",
        wrap(b64(m.text)),
        "--#{boundary}",
        "Content-Type: text/html; charset=utf-8",
        "Content-Transfer-Encoding: base64",
        "",
        wrap(b64(m.html)),
        "--#{boundary}--",
        ""
      ],
      "\r\n"
    )
  end

  @doc """
  Sends one message. Each reply must come within 20 s, and the whole send
  within the deadline (60 s), so a server that trickles a line now and then
  cannot hold the scheduled check that sends reports. `opts` may give `:now`
  and `:uuid` for the message, as tests do.
  """
  @spec send(map(), map(), String.t(), pos_integer(), keyword()) :: :ok
  def send(config, m, from, deadline \\ 60_000, opts \\ []) do
    host = Runlight.JS.trim(config["host"])
    security = if config["security"] in [nil, ""], do: "starttls", else: config["security"]

    port =
      case Runlight.JS.number(config["port"]) do
        n when is_integer(n) and n != 0 -> n
        _ -> if security == "tls", do: 465, else: 587
      end

    task =
      Task.async(fn ->
        try do
          converse(config, m, from, host, port, security, opts)
        rescue
          error -> {:error, MailError.exception(message: "SMTP: #{Exception.message(error)}")}
        end
      end)

    case Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, error}} ->
        raise error

      nil ->
        raise MailError,
          message: "SMTP: #{host}:#{port} took longer than #{Runlight.JS.round(deadline / 1000)} s",
          code: "mail_slow",
          params: %{"host" => "#{host}:#{port}"}

      {:exit, reason} ->
        raise MailError, message: "SMTP: #{inspect(reason)}"
    end
  end

  @timeout 20_000

  defp converse(config, m, from, host, port, security, opts) do
    tls = tls_options(host)

    connect =
      if security == "tls",
        do: &:ssl.connect(&1, &2, [:binary, active: false] ++ tls, @timeout),
        else: &:gen_tcp.connect(&1, &2, [:binary, active: false], @timeout)

    case connect.(String.to_charlist(host), port) do
      {:error, reason} ->
        detail = describe(reason)

        {:error,
         MailError.exception(
           message: "SMTP: could not connect to #{host}:#{port}: #{detail}",
           code: "mail_unreachable",
           params: %{"host" => "#{host}:#{port}", "detail" => detail}
         )}

      {:ok, socket} ->
        mod = if security == "tls", do: :ssl, else: :gen_tcp
        conn = %{mod: mod, socket: socket, buffer: ""}

        try do
          conversation(conn, config, m, from, host, security, tls, opts)
        catch
          {:smtp, error, conn} ->
            close(conn)
            {:error, error}
        end
    end
  end

  defp conversation(conn, config, m, from, _host, security, tls, opts) do
    conn = expect(conn, [220], "greeting") |> elem(0)

    name =
      case String.split(from, "@") do
        [_, rest | _] -> rest |> String.replace(~r/>$/, "") |> then(&if(&1 == "", do: "localhost", else: &1))
        _ -> "localhost"
      end

    conn = write(conn, "EHLO #{name}")
    {conn, ehlo} = expect(conn, [250], "EHLO")

    conn =
      if security == "starttls" do
        unless Regex.match?(~r/STARTTLS/i, ehlo.text),
          do:
            throw(
              {:smtp,
               MailError.exception(
                 message: "SMTP: the server does not offer STARTTLS; pick tls or none",
                 code: "smtp_starttls",
                 params: %{}
               ), conn}
            )

        conn = write(conn, "STARTTLS")
        {conn, _} = expect(conn, [220], "STARTTLS")

        case :ssl.connect(conn.socket, tls, @timeout) do
          {:ok, secured} ->
            conn = %{mod: :ssl, socket: secured, buffer: ""}
            conn = write(conn, "EHLO #{name}")
            {conn, _} = expect(conn, [250], "EHLO")
            conn

          {:error, reason} ->
            throw({:smtp, MailError.exception(message: "SMTP: TLS failed: #{describe(reason)}"), conn})
        end
      else
        conn
      end

    conn =
      if config["username"] not in [nil, ""] do
        conn = write(conn, "AUTH PLAIN #{b64("\0#{config["username"]}\0#{config["password"] || ""}")}")
        expect(conn, [235], "sign-in") |> elem(0)
      else
        conn
      end

    conn = write(conn, "MAIL FROM:<#{m.from}>")
    {conn, _} = expect(conn, [250], "MAIL FROM")
    conn = write(conn, "RCPT TO:<#{m.to}>")
    {conn, _} = expect(conn, [250, 251], "RCPT TO")
    conn = write(conn, "DATA")
    {conn, _} = expect(conn, [354], "DATA")
    # A line starting with a dot gets a second one, so it is not read as the end.
    body = mime(m, from, Keyword.get(opts, :now, System.os_time(:millisecond)), Keyword.get(opts, :uuid, &uuid/0))
    send_raw(conn, String.replace(body, "\r\n.", "\r\n..") <> "\r\n.\r\n")
    {conn, _} = expect(conn, [250], "message")
    conn = write(conn, "QUIT")

    # Wait for the goodbye, but never fail a sent message over it.
    try do
      read_reply(conn, 2000)
    catch
      {:smtp, _, _} -> :ok
    end

    close(conn)
    :ok
  end

  defp tls_options(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp close(%{mod: mod, socket: socket}), do: mod.close(socket)

  defp write(conn, line) do
    send_raw(conn, line <> "\r\n")
    conn
  end

  defp send_raw(conn, data) do
    case conn.mod.send(conn.socket, data) do
      :ok -> :ok
      {:error, reason} -> throw({:smtp, MailError.exception(message: "SMTP: #{describe(reason)}"), conn})
    end
  end

  defp expect(conn, codes, what) do
    {conn, reply} = read_reply(conn, @timeout)

    if reply.code in codes do
      {conn, reply}
    else
      message = Runlight.JS.slice("SMTP #{what}: #{reply.code} #{reply.text}", 0, 300)
      throw({:smtp, MailError.exception(message: message), conn})
    end
  end

  # One reply, multi-line included: its code and its lines' text joined with spaces.
  defp read_reply(conn, timeout), do: read_reply(conn, timeout, [])

  defp read_reply(conn, timeout, lines) do
    case :binary.split(conn.buffer, "\r\n") do
      [line, rest] ->
        conn = %{conn | buffer: rest}
        lines = lines ++ [Runlight.JS.slice(line, 4)]

        if String.at(line, 3) == "-" do
          read_reply(conn, timeout, lines)
        else
          code = Runlight.JS.number(binary_part(line, 0, min(3, byte_size(line))))
          {conn, %{code: code, text: Enum.join(lines, " ")}}
        end

      [_] ->
        case conn.mod.recv(conn.socket, 0, timeout) do
          {:ok, data} ->
            read_reply(%{conn | buffer: conn.buffer <> data}, timeout, lines)

          {:error, :closed} ->
            throw({:smtp, MailError.exception(message: "SMTP: the server closed the connection"), conn})

          {:error, :timeout} ->
            throw({:smtp, MailError.exception(message: "SMTP: timed out"), conn})

          {:error, reason} ->
            throw({:smtp, MailError.exception(message: "SMTP: #{describe(reason)}"), conn})
        end
    end
  end

  defp describe(reason) do
    case reason do
      atom when is_atom(atom) -> atom |> :inet.format_error() |> to_string()
      other -> other |> :ssl.format_error() |> to_string()
    end
  end
end
