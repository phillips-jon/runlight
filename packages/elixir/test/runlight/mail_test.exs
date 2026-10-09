defmodule Runlight.MailTest do
  @moduledoc """
  The SDK's mail.test.ts, and the mail parts of the outbound fixture
  (scripts/php-fixtures-outbound.mts): every service sends the TypeScript
  SDK's exact requests, SigV4 signs as AWS and the SDK do, MIME is written
  the same, and an SMTP server hears the same conversation.
  """
  use ExUnit.Case, async: true

  alias Runlight.Crypto
  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Mail
  alias Runlight.Mail.Ses
  alias Runlight.Mail.Smtp
  alias Runlight.MailError
  alias Runlight.Test.Fixtures
  alias Runlight.Test.SmtpServer

  @message %{
    to: "jon@example.com",
    from: "reports@example.com",
    from_name: "Runlight",
    subject: "Hello",
    html: "<p>Hi</p>",
    text: "Hi",
    headers: [{"List-Unsubscribe", "<https://x/u>"}]
  }

  setup_all do
    {:ok, fixture: Fixtures.php("outbound.json")}
  end

  defp message(%Object{} = m) do
    %{
      to: m["to"],
      from: m["from"],
      from_name: m["fromName"],
      subject: m["subject"],
      html: m["html"],
      text: m["text"],
      headers: if(m["headers"], do: Object.to_list(m["headers"]), else: nil)
    }
  end

  # Records every request, its headers sorted by name as iterating Fetch Headers gives them.
  defp recorder(answer) do
    me = self()

    fn url, opts ->
      headers = opts |> Keyword.get(:headers, []) |> Enum.map(fn {k, v} -> {String.downcase(k), v} end) |> Enum.sort()

      send(
        me,
        {:request,
         JS.obj(
           method: Keyword.get(opts, :method, "GET"),
           url: url,
           headers: JS.obj(headers),
           body: Keyword.get(opts, :body, "")
         )}
      )

      answer.()
    end
  end

  defp requests(acc \\ []) do
    receive do
      {:request, r} -> requests(acc ++ [r])
    after
      0 -> acc
    end
  end

  # JSON with every object's keys sorted, as deepEqual compares them.
  defp canon(v), do: JS.stringify(sorted(v))

  defp sorted(%Object{} = o),
    do: o |> Object.to_list() |> Enum.sort() |> Enum.map(fn {k, v} -> {k, sorted(v)} end) |> Object.new()

  defp sorted(l) when is_list(l), do: Enum.map(l, &sorted/1)
  defp sorted(v), do: v

  defp uuids do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(:counters.get(counter, 1)), 12, "0")
    end
  end

  test "keys sealed by TypeScript open here, and only with the same secret", %{fixture: f} do
    for c <- f["sealed"] do
      assert Crypto.unseal(c["sealed"], c["secret"]) == c["value"]
      assert Crypto.unseal(c["sealed"], c["secret"] <> "!") == nil
      # A key that does not open (an IV under 12 bytes) has no value to seal again.
      if c["value"] != nil, do: assert(Crypto.unseal(Crypto.seal(c["value"], c["secret"]), c["secret"]) == c["value"])
    end

    assert Crypto.unseal(Crypto.seal("x", nil), nil) == "x"
    assert Crypto.unseal("v1:AAAA:AAAA", "server secret") == nil
    assert Crypto.unseal("v2:a:b", "server secret") == nil
  end

  test "SigV4 matches AWS's published example and the SDK", %{fixture: f} do
    headers =
      Ses.sign_v4(%{
        method: "GET",
        url: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08",
        body: "",
        region: "us-east-1",
        service: "iam",
        access_key_id: "AKIDEXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        now: 1_440_938_160_000,
        headers: [{"content-type", "application/x-www-form-urlencoded; charset=utf-8"}]
      })

    assert List.keyfind(headers, "authorization", 0) ==
             {"authorization",
              "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"}

    for c <- f["signatures"] do
      i = c["input"]

      got =
        Ses.sign_v4(%{
          method: i["method"],
          url: i["url"],
          body: i["body"],
          region: i["region"],
          service: i["service"],
          access_key_id: i["accessKeyId"],
          secret_access_key: i["secretAccessKey"],
          now: i["now"],
          headers: Object.to_list(i["headers"])
        })

      assert JS.obj(got) == c["headers"], i["url"]
    end
  end

  test "every service sends the TypeScript requests exactly", %{fixture: f} do
    for {c, i} <- Enum.with_index(f["mail"]) do
      answer = c["answer"]

      fetch =
        recorder(fn ->
          if answer == "unreachable",
            do: {:error, %RuntimeError{message: "fetch failed"}},
            else: {:ok, %Response{status: answer["status"], body: answer["body"]}}
        end)

      error =
        try do
          Mail.deliver(fetch, c["config"], message(c["message"]), now: f["now"])
          nil
        rescue
          e in MailError -> JS.obj(message: e.message, code: e.code, params: JS.obj(e.params))
        end

      label = "case #{i}: #{JS.stringify(c["config"])}"
      assert JS.stringify(requests()) == JS.stringify(c["requests"]), label
      assert canon(error) == canon(c["error"]), label
    end
  end

  test "each service gets the request it documents" do
    ok = fn -> {:ok, %Response{status: 200, body: "{}"}} end
    Mail.deliver(recorder(ok), JS.obj(service: "resend", apiKey: "re_1"), @message)
    [r] = requests()
    assert r["url"] == "https://api.resend.com/emails"
    assert r["headers"]["authorization"] == "Bearer re_1"
    assert JS.parse!(r["body"])["from"] == "Runlight <reports@example.com>"

    Mail.deliver(recorder(ok), JS.obj(service: "webhook", url: "https://hooks.example.com/mail", secret: "s"), @message)
    [r] = requests()
    assert r["headers"]["x-runlight-signature"] =~ ~r/\Asha256=[a-f0-9]{64}\z/

    refused = fn -> {:ok, %Response{status: 401, body: "nope"}} end

    assert_raise MailError, ~r/api.sendgrid.com answered 401/, fn ->
      Mail.deliver(recorder(refused), JS.obj(service: "sendgrid", apiKey: "bad"), @message)
    end

    assert_raise MailError, ~r/must use https/, fn ->
      Mail.deliver(recorder(refused), JS.obj(service: "webhook", url: "http://example.com/x"), @message)
    end

    assert_raise MailError, ~r/Enter the api key/, fn ->
      Mail.deliver(recorder(refused), JS.obj(service: "resend"), @message)
    end

    assert hd(Mail.services())["id"] == "ses"

    assert %MailError{code: "mail_failed", params: %{"detail" => "Something"}} =
             MailError.exception(message: "Something")
  end

  test "service messages match TypeScript", %{fixture: f} do
    for c <- f["replies"], do: assert(Mail.service_message(c["reply"]) == c["message"], c["reply"])
  end

  test "MIME matches TypeScript", %{fixture: f} do
    for c <- f["mimes"] do
      assert Smtp.mime(message(c["message"]), c["from"], c["now"], uuids()) == c["mime"]
    end

    raw = Smtp.mime(%{@message | subject: "Café report"}, "Runlight <reports@example.com>")
    assert raw =~ ~r/Subject: =\?UTF-8\?B\?/
    assert raw =~ ~r/boundary="rl-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"/
  end

  test "SMTP has the TypeScript conversation", %{fixture: f} do
    {port, pid} = SmtpServer.start()

    for c <- f["smtp"] do
      config =
        c["config"]
        |> Object.put("service", "smtp")
        |> Object.put("host", "127.0.0.1")
        |> Object.put("port", Integer.to_string(port))

      error =
        try do
          Smtp.send(config, message(c["message"]), c["from"], 60_000, now: f["now"], uuid: uuids())
          nil
        rescue
          e in MailError -> JS.obj(message: e.message, code: e.code, params: JS.obj(e.params))
        end

      assert canon(error) == canon(c["error"])
      assert SmtpServer.conversation().received == c["received"]
    end

    SmtpServer.stop(pid)
  end

  test "SMTP through the transports sends too" do
    {port, pid} = SmtpServer.start()

    Mail.deliver(
      fn _, _ -> raise "no fetch" end,
      JS.obj(service: "smtp", host: "127.0.0.1", port: "#{port}", security: "none"),
      @message
    )

    assert SmtpServer.conversation().received =~ "From: Runlight <reports@example.com>\r\n"
    SmtpServer.stop(pid)
  end

  test "an SMTP server that trickles is cut off at the deadline" do
    {port, pid} = SmtpServer.start(:trickle)
    started = System.monotonic_time(:millisecond)

    error =
      assert_raise MailError, fn ->
        Smtp.send(
          JS.obj(service: "smtp", host: "127.0.0.1", port: "#{port}", security: "none"),
          @message,
          "reports@example.com",
          600
        )
      end

    assert error.code == "mail_slow"
    assert error.params == %{"host" => "127.0.0.1:#{port}"}
    assert error.message == "SMTP: 127.0.0.1:#{port} took longer than 1 s"
    assert System.monotonic_time(:millisecond) - started < 2000
    assert SmtpServer.conversation(2000).closed
    SmtpServer.stop(pid)
  end

  test "SMTP that cannot connect says so" do
    {:ok, probe} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(probe)
    :gen_tcp.close(probe)

    error =
      assert_raise MailError, fn ->
        Smtp.send(
          JS.obj(service: "smtp", host: "127.0.0.1", port: "#{port}", security: "none"),
          @message,
          "reports@example.com"
        )
      end

    assert error.code == "mail_unreachable"
    assert List.keyfind(error.params, "host", 0) == {"host", "127.0.0.1:#{port}"}
    assert String.starts_with?(error.message, "SMTP: could not connect to 127.0.0.1:#{port}: ")
  end
end
