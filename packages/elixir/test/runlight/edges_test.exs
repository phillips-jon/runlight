defmodule Runlight.EdgesTest do
  @moduledoc "The SDK's edges.test.ts: odd input at the edges of mail, MCP, the assistant, icons, importers, and connect."
  use ExUnit.Case, async: true

  alias Runlight.Assistant
  alias Runlight.AssistantError
  alias Runlight.Connect
  alias Runlight.ConnectError
  alias Runlight.Http.Request
  alias Runlight.Http.Response
  alias Runlight.Icon
  alias Runlight.ImportError
  alias Runlight.Importers
  alias Runlight.JS
  alias Runlight.Mail
  alias Runlight.MailError
  alias Runlight.Mcp
  alias Runlight.Store
  alias Runlight.Test.FakeFetcher
  alias Runlight.Test.Stores

  defp code(fun) do
    fun.()
    nil
  rescue
    e in [MailError, ConnectError, AssistantError, ImportError] -> e.code
  end

  defp rl(fetcher \\ nil) do
    {store, cleanup} = Stores.store(:sqlite)
    on_exit(cleanup)
    rl = Runlight.new(store: store, managed_sites: true, secret: String.duplicate("k", 32), fetcher: fetcher)
    Runlight.init(rl)
    rl
  end

  test "mail: Basic auth carries a key as UTF-8, whatever its characters" do
    {fetcher, agent} = FakeFetcher.new(fn _, _ -> {:ok, Response.new("{}")} end)
    rl = rl(fetcher)
    message = %{to: "jon@example.com", from: "reports@example.com", subject: "Hello", html: "<p>Hi</p>", text: "Hi"}
    Mail.send(rl, JS.obj(service: "mailgun", apiKey: "ключ", domain: "mg.example.com", region: "us"), message)
    Mail.send(rl, JS.obj(service: "mailjet", apiKey: "mj", secretKey: "kéy 😀"), message)

    assert Enum.map(FakeFetcher.requests(agent), & &1["headers"]["authorization"]) == [
             "Basic " <> Base.encode64("api:ключ"),
             "Basic " <> Base.encode64("mj:kéy 😀")
           ]
  end

  test "mail: an SMTP port out of range is refused before anything is saved or sent" do
    smtp = &JS.obj(service: "smtp", host: "smtp.example.com", port: &1, security: "starttls")

    for port <- ~w(70000 65536 0 -1 1.5 abc Infinity 0x10000),
        do: assert(code(fn -> Mail.check_config(smtp.(port)) end) == "mail_port", port)

    for port <- ["587", " 465 ", "65535", "1", "0o1", "0b11", "25.0"],
        do: assert(code(fn -> Mail.check_config(smtp.(port)) end) == nil, port)
  end

  test "mail: a webhook address that is not a URL is refused before anything is saved or sent" do
    for url <- ["https://", "https://[", "https:// /x"] do
      error = assert_raise MailError, fn -> Mail.check_config(JS.obj(service: "webhook", url: url)) end
      assert error.code == "mail_url", url
      assert error.message == "Enter the webhook's whole URL, like https://example.com/hooks/mail"
    end

    assert code(fn -> Mail.check_config(JS.obj(service: "webhook", url: "https://hooks.example.com/mail")) end) == nil
    assert code(fn -> Mail.check_config(JS.obj(service: "webhook", url: "http://example.com/x")) end) == "mail_https"
  end

  defp mcp(body) do
    me = self()

    answer =
      Mcp.response(Request.new("https://x.com/mcp", method: "POST", body: JS.stringify(body)), fn path, _ ->
        send(me, {:asked, path})
        Response.new(~s({"ok":true}))
      end)

    asked = Stream.repeatedly(fn -> receive(do: ({:asked, p} -> p), after: (0 -> nil)) end) |> Enum.take_while(& &1)
    {answer.status, if(answer.status == 202, do: nil, else: JS.parse!(Response.text(answer))), asked}
  end

  test "MCP: a notification runs nothing and is answered with nothing" do
    assert mcp(JS.obj(jsonrpc: "2.0", method: "tools/call", params: JS.obj(name: "get_stats"))) == {202, nil, []}
    assert mcp([JS.obj(jsonrpc: "2.0", method: "tools/call", params: JS.obj(name: "list_sites"))]) == {202, nil, []}
  end

  test "MCP: a batch element that is not an object is an invalid request of its own" do
    invalid = JS.obj(jsonrpc: "2.0", id: nil, error: JS.obj(code: -32_600, message: "Invalid request"))
    {status, body, _} = mcp([nil, JS.obj(jsonrpc: "2.0", id: 1, method: "ping"), 5, []])
    assert status == 200
    assert body == [invalid, JS.obj(jsonrpc: "2.0", id: 1, result: JS.obj([])), invalid, invalid]
    assert mcp([nil]) == {200, [invalid], []}
  end

  test "MCP: a refusal whose body is null or not an object reads like any other refusal" do
    for body <- ["null", "5", ~s("text"), "[1]"] do
      result = Mcp.call_tool(JS.obj(name: "list_sites"), fn _, _ -> Response.new(body, 403) end)
      assert result == JS.obj(content: [JS.obj(type: "text", text: "Runlight answered 403")], isError: true), body
    end

    # An answer that is fine but not an object is passed on as it is, even through a tool that reshapes its answers.
    for body <- ["null", "[1]", "5"] do
      fine = Mcp.call_tool(JS.obj(name: "get_visit_times"), fn _, _ -> Response.new(body) end)
      assert fine == JS.obj(content: [JS.obj(type: "text", text: body)]), body
    end
  end

  @context %{
    site: %{id: "default", name: "Site", timezone: "UTC"},
    today: "2026-10-08",
    view: "today",
    language: "en"
  }

  defp answering(body), do: rl(fn _, _ -> {:ok, Response.new(body)} end)

  test "assistant: an answer in a shape it cannot read is assistant_failed, for every protocol" do
    answers = [
      {"anthropic", ~s({"content":"text"})},
      {"anthropic", ~s({"content":[null]})},
      {"anthropic",
       ~s({"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t","name":"list_sites","input":{}},5]})},
      {"anthropic", ~s({"content":{"type":"text"}})},
      {"openai", ~s({"choices":[{"message":{"tool_calls":"abc"}}]})},
      {"openai", ~s({"choices":[{"message":{"tool_calls":[null]}}]})},
      {"openai", ~s({"choices":[{"message":{"tool_calls":[{}]}}]})},
      {"openai", ~s({"choices":[{"message":{"tool_calls":[{"id":"c","function":null}]}}]})},
      {"openai", ~s({"choices":[{"message":{"tool_calls":{"length":1}}}]})}
    ]

    for {provider, body} <- answers do
      settings = JS.obj(provider: provider, model: "m", baseUrl: "", key: "k")
      read = fn _, _ -> Response.new("{}") end

      error =
        assert_raise AssistantError, fn ->
          Assistant.chat(answering(body), settings, [%{role: "user", content: "How many visitors?"}], @context, read)
        end

      assert error.code == "assistant_failed", body
      assert error.message =~ "sent an answer Runlight could not read"
    end

    for body <- [~s({"data":"x"}), ~s({"data":{}})] do
      error =
        assert_raise AssistantError, fn ->
          Assistant.list_models(answering(body), JS.obj(provider: "openai", baseUrl: "", key: "k"))
        end

      assert error.code == "assistant_failed", body
    end

    # A list with entries that are not models is read like one with entries that have no id.
    models = Assistant.list_models(answering(~s({"data":[null,5,{"id":"m1"}]})), JS.obj(provider: "openai", key: "k"))
    assert models == [JS.obj(id: "m1", name: "m1")]
  end

  test "icons: only the rel attribute itself says what a link is" do
    base = "https://example.com/"
    assert Icon.icon_links(~s(<link data-rel="x" rel="icon" href="/a.png">), base) == ["https://example.com/a.png"]

    assert Icon.icon_links(~s(<link rel="icon" data-href="/wrong.png" href="/right.png">), base) == [
             "https://example.com/right.png"
           ]

    assert Icon.icon_links(~s(<link title="rel=icon" rel="stylesheet" href="/s.css">), base) == []

    assert Icon.icon_links(~s(<link rel="icon" href="/first.png" href="/second.png">), base) == [
             "https://example.com/first.png"
           ]
  end

  test "importers: a source or name like a property of every JavaScript object is just a name" do
    rl = rl()

    for source <- ~w(constructor toString __proto__ hasOwnProperty),
        do: assert(code(fn -> Importers.import_step(rl, "default", source, %{}, nil, 0) end) == "import_source")

    assert Enum.map(~w(constructor __proto__ toString), &Importers.browser_name/1) == ~w(Constructor __proto__ ToString)
    assert Enum.map(~w(constructor toString), &Importers.system_name/1) == ~w(constructor toString)
    assert Enum.map(~w(constructor valueOf), &Importers.device_name/1) == ["", ""]
  end

  test "connect: an attempt saved without an expiry has expired" do
    {fetcher, agent} = FakeFetcher.new(fn _, _ -> raise "nothing should be fetched" end)
    rl = rl(fetcher)
    state = String.duplicate("a", 32)

    for stored <- [
          JS.obj(
            url: "https://example.com",
            client: "c",
            verifier: "v",
            redirect: "https://x.com/back",
            token: "https://example.com/token"
          ),
          nil,
          5,
          JS.obj(expires: "9999999999999")
        ] do
      Store.set_setting(rl.store, "connect:#{state}", JS.stringify(stored))

      assert code(fn -> Connect.finish_connect(rl, [{"state", state}, {"code", "c"}]) end) == "expired",
             JS.stringify(stored)
    end

    assert FakeFetcher.requests(agent) == []
  end

  test "connect: an address the URL parser refuses is the address error" do
    for url <- ["https://[", "https://[::1", "https://a b"],
        do: assert(code(fn -> Connect.install_url(url) end) == "url")

    assert Connect.install_url("https://example.com/runlight/") == "https://example.com/runlight"
  end
end
