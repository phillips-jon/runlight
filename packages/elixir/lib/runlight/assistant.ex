defmodule Runlight.Assistant do
  @moduledoc false
  # Internal. The dashboard's assistant: questions about the stats, answered
  # by a model the owner chooses, through the same read-only tools as the MCP
  # server (the SDK's assistant.ts). Two protocols cover the providers:
  # Anthropic's Messages API, and OpenAI's Chat Completions.

  alias Runlight.AssistantError
  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Mcp
  alias Runlight.Url

  @max_rounds 8
  # However many rounds a question takes, the answer comes within this long or the assistant stops.
  @deadline_ms 120_000
  @max_tokens 1500

  @doc "The services the assistant can use, as the setup form lists them."
  def providers do
    [
      JS.obj(
        id: "anthropic",
        name: "Anthropic (Claude)",
        protocol: "anthropic",
        baseUrl: "https://api.anthropic.com/v1",
        model: "claude-sonnet-5-5",
        key: "yes"
      ),
      JS.obj(
        id: "openai",
        name: "OpenAI",
        protocol: "openai",
        baseUrl: "https://api.openai.com/v1",
        model: "",
        key: "yes"
      ),
      JS.obj(
        id: "gemini",
        name: "Google Gemini",
        protocol: "openai",
        baseUrl: "https://generativelanguage.googleapis.com/v1beta/openai",
        model: "",
        key: "yes"
      ),
      JS.obj(
        id: "openrouter",
        name: "OpenRouter",
        protocol: "openai",
        baseUrl: "https://openrouter.ai/api/v1",
        model: "",
        key: "yes"
      ),
      JS.obj(
        id: "ollama",
        name: "Ollama",
        protocol: "openai",
        baseUrl: "http://localhost:11434/v1",
        model: "",
        key: "no"
      ),
      JS.obj(
        id: "lmstudio",
        name: "LM Studio",
        protocol: "openai",
        baseUrl: "http://localhost:1234/v1",
        model: "",
        key: "no"
      ),
      JS.obj(
        id: "custom",
        name: "Another OpenAI-compatible service",
        protocol: "openai",
        baseUrl: "",
        model: "",
        key: "optional"
      )
    ]
  end

  defp system(context) do
    """
    #{Mcp.instructions()}

    You are the assistant inside this Runlight dashboard. Today is #{context.today} in #{context.site.timezone}. The person is looking at the site "#{context.site.name}" (id #{context.site.id}) for #{context.view}. Unless they ask about another site or range, use this site and these dates.

    When a question needs numbers, read them with the tools first and never guess one. Answer in a few short sentences or a short list, in plain language, and name the dates you looked at.

    Rule: answer only the newest message. If it asks nothing new (thanks, a greeting, "great", "that helps"), reply with one short friendly sentence, call no tools, and do not repeat, summarise, or re-check any earlier answer. Only go back to earlier numbers when the person asks about them again. Bounce rate is a fraction from 0 to 1 and durations are milliseconds in the tools; give them as a percent and in seconds or minutes. Write in the language whose code is "#{context.language}".\
    """
  end

  @too_long "That question took too long to answer. Try asking something narrower."

  defp clock, do: System.monotonic_time(:millisecond)

  defp in_time(deadline) do
    if clock() >= deadline, do: raise(AssistantError, message: @too_long, code: "assistant_slow")
  end

  defp host_of(url), do: Url.host(Url.new(url))

  defp post(rl, url, headers, body, deadline) do
    in_time(deadline)
    left = deadline - clock()

    case Runlight.fetch(rl, url,
           method: "POST",
           headers: [{"content-type", "application/json"} | headers],
           body: JS.stringify(body),
           timeout: min(90_000, left)
         ) do
      {:error, :timeout} ->
        host = host_of(url)

        raise AssistantError,
          message: "Could not reach #{host}: it took too long to answer",
          code: "assistant_timeout",
          params: [{"host", host}]

      {:error, _} ->
        host = host_of(url)

        raise AssistantError,
          message: "Could not reach #{host}: the connection failed",
          code: "unreachable",
          params: [{"host", host}]

      {:ok, answer} ->
        data =
          case Response.json(answer),
            do: (
              {:ok, d} -> d
              :error -> nil
            )

        if Response.ok?(answer) do
          if data == nil, do: Object.new(), else: data
        else
          refused(url, answer.status, data)
        end
    end
  end

  # The service's own message, never the request (it carries the key).
  defp refused(url, status, data) do
    error = JS.prop(data, "error")

    message =
      cond do
        is_binary(error) -> error
        is_binary(JS.prop(error, "message")) -> JS.prop(error, "message")
        true -> ""
      end

    host = host_of(url)

    if message == "" do
      raise AssistantError,
        message: "#{host}: it answered #{status}",
        code: "assistant_status",
        params: [{"host", host}, {"status", "#{status}"}]
    else
      detail = JS.slice(message, 0, 300)

      raise AssistantError,
        message: "#{host}: #{detail}",
        code: "assistant_refused",
        params: [{"host", host}, {"detail", detail}]
    end
  end

  defp tool_text(name, args, read_api) do
    result =
      Mcp.call_tool(JS.obj(name: name, arguments: if(JS.objectish?(args), do: args, else: Object.new())), read_api)

    content = result["content"]
    %{text: (List.first(content) || %{})["text"] || "", error: result["isError"] == true}
  rescue
    error -> %{text: Exception.message(error), error: true}
  catch
    {:rpc, _, message} -> %{text: message, error: true}
  end

  @welcome %{
    "en" => "You're welcome. Ask me anything else about your stats.",
    "fr" => "Avec plaisir. Demandez-moi autre chose sur vos statistiques.",
    "es" => "De nada. Pregúntame lo que quieras sobre tus estadísticas.",
    "de" => "Gern geschehen. Frag mich gern noch etwas zu deinen Statistiken.",
    "pt" => "De nada. Pergunte o que quiser sobre suas estatísticas."
  }

  @doc "A short reply to a message that only says thanks or OK, or nil when the message asks something."
  def acknowledgement(text, language) do
    plain = text |> String.replace(~r/\p{Extended_Pictographic}|\x{FE0F}/u, " ") |> JS.trim()
    welcome = Map.get(@welcome, language, @welcome["en"])

    cond do
      plain == "" and JS.trim(text) != "" ->
        welcome

      Regex.match?(
        ~r/^(?:(?:thanks|thank you|thank you so much|thanks a lot|thx|ty|cheers|ok|okay|great|cool|nice|perfect|awesome|got it|good|merci|merci beaucoup|super|parfait|d'accord|gracias|muchas gracias|vale|genial|perfecto|danke|danke schön|vielen dank|prima|alles klar|obrigado|obrigada|valeu|ótimo|beleza)[\s!.,]*)+$/iu,
        plain
      ) and not String.ends_with?(plain, "\n") ->
        welcome

      true ->
        nil
    end
  end

  defp provider!(settings) do
    Enum.find(providers(), &(&1["id"] == JS.prop(settings, "provider")))
  end

  @doc "Answers the last question in `messages`, calling tools as the model asks: {reply, tools}."
  def chat(rl, settings, messages, context, read_api) do
    provider =
      provider!(settings) ||
        raise(AssistantError, message: "Choose a provider in Settings, AI Assistant", code: "assistant_provider")

    base = JS.or_else(settings["baseUrl"], provider["baseUrl"]) |> String.replace(~r/\/+\z/, "")

    if base == "",
      do:
        raise(AssistantError,
          message: "Enter the service's address in Settings, AI Assistant",
          code: "assistant_address"
        )

    model = JS.or_else(settings["model"], provider["model"])

    if model == "",
      do: raise(AssistantError, message: "Enter a model in Settings, AI Assistant", code: "assistant_model")

    # "Thanks!" needs no model, no tools, and certainly not the last answer again.
    case acknowledgement((List.last(messages) || %{content: ""}).content, context.language) do
      nil -> converse(rl, settings, provider, base, model, messages, context, read_api)
      thanks -> JS.obj(reply: thanks, tools: [])
    end
  end

  defp converse(rl, settings, provider, base, model, messages, context, read_api) do
    deadline = clock() + @deadline_ms
    # The last twenty turns, starting with a question, with unanswered questions in a row joined into one.
    recent = messages |> Enum.take(-20) |> Enum.drop_while(&(&1.role != "user"))

    history =
      Enum.reduce(recent, [], fn m, history ->
        content = m.content |> JS.string() |> JS.slice(0, 8000)

        case List.last(history) do
          %{role: role} = last when role == m.role ->
            List.replace_at(history, -1, %{last | content: last.content <> "\n\n" <> content})

          _ ->
            history ++ [%{role: m.role, content: content}]
        end
      end)
      |> Enum.map(&JS.obj(role: &1.role, content: &1.content))

    if provider["protocol"] == "anthropic",
      do: anthropic(rl, settings, base, model, history, context, read_api, deadline),
      else: openai(rl, settings, provider, base, model, history, context, read_api, deadline)
  end

  defp steps_error,
    do:
      raise(AssistantError,
        message: "The assistant needed too many steps for that question. Try asking something narrower.",
        code: "assistant_steps"
      )

  defp anthropic(rl, settings, base, model, convo, context, read_api, deadline) do
    tools = Enum.map(Mcp.tools(), &JS.obj(name: &1.name, description: &1.description, input_schema: &1.input_schema))

    result =
      Enum.reduce_while(1..@max_rounds, {convo, []}, fn _, {convo, used} ->
        data =
          post(
            rl,
            "#{base}/messages",
            [{"x-api-key", settings["key"]}, {"anthropic-version", "2023-06-01"}],
            JS.obj(model: model, max_tokens: @max_tokens, system: system(context), tools: tools, messages: convo),
            deadline
          )

        blocks =
          case JS.prop(data, "content"),
            do: (
              l when is_list(l) -> l
              _ -> []
            )

        calls = Enum.filter(blocks, &(JS.prop(&1, "type") == "tool_use"))

        if JS.prop(data, "stop_reason") != "tool_use" or calls == [] do
          reply =
            blocks
            |> Enum.filter(&(JS.prop(&1, "type") == "text"))
            |> Enum.map_join("\n", &JS.string(JS.nullish(JS.prop(&1, "text"), "")))
            |> JS.trim()

          {:halt, {:done, JS.obj(reply: reply, tools: used)}}
        else
          convo = convo ++ [JS.obj(role: "assistant", content: blocks)]

          {results, used} =
            Enum.reduce(calls, {[], used}, fn call, {results, used} ->
              # The deadline covers the reading too, however many tools one answer asks for.
              in_time(deadline)
              name = JS.string(JS.nullish(JS.prop(call, "name"), ""))
              out = tool_text(name, JS.prop(call, "input"), read_api)
              result = JS.obj(type: "tool_result", tool_use_id: JS.prop(call, "id"), content: out.text)
              result = if out.error, do: Object.put(result, "is_error", true), else: result
              {results ++ [result], used ++ [name]}
            end)

          {:cont, {convo ++ [JS.obj(role: "user", content: results)], used}}
        end
      end)

    case result do
      {:done, answer} -> answer
      _ -> steps_error()
    end
  end

  defp openai(rl, settings, provider, base, model, history, context, read_api, deadline) do
    tools =
      Enum.map(
        Mcp.tools(),
        &JS.obj(
          type: "function",
          function: JS.obj(name: &1.name, description: &1.description, parameters: &1.input_schema)
        )
      )

    convo = [JS.obj(role: "system", content: system(context)) | history]
    headers = if JS.truthy?(settings["key"]), do: [{"authorization", "Bearer #{settings["key"]}"}], else: []

    result =
      Enum.reduce_while(1..@max_rounds, {convo, []}, fn _, {convo, used} ->
        # OpenAI's newer models take max_completion_tokens and refuse max_tokens; the other services still take
        # max_tokens.
        body =
          if provider["id"] == "openai",
            do: JS.obj(model: model, max_completion_tokens: @max_tokens, messages: convo, tools: tools),
            else: JS.obj(model: model, max_tokens: @max_tokens, messages: convo, tools: tools)

        data = post(rl, "#{base}/chat/completions", headers, body, deadline)

        message =
          case JS.prop(data, "choices") do
            [first | _] ->
              case JS.prop(first, "message"),
                do: (
                  %Object{} = m -> m
                  _ -> Object.new()
                )

            _ ->
              Object.new()
          end

        calls =
          case JS.prop(message, "tool_calls"),
            do: (
              l when is_list(l) and l != [] -> l
              _ -> nil
            )

        if calls == nil do
          {:halt,
           {:done,
            JS.obj(reply: message |> JS.prop("content") |> JS.nullish("") |> JS.string() |> JS.trim(), tools: used)}}
        else
          convo =
            convo ++
              [JS.obj(role: "assistant", content: JS.nullish(JS.prop(message, "content"), nil), tool_calls: calls)]

          {convo, used} =
            Enum.reduce(calls, {convo, used}, fn call, {convo, used} ->
              in_time(deadline)
              function = JS.prop(call, "function")
              name = JS.prop(function, "name")
              raw = JS.prop(function, "arguments")
              args = JS.parse_or(if(JS.truthy?(raw), do: JS.string(raw), else: "{}"), Object.new())
              out = tool_text(name, args, read_api)
              {convo ++ [JS.obj(role: "tool", tool_call_id: JS.prop(call, "id"), content: out.text)], used ++ [name]}
            end)

          {:cont, {convo, used}}
        end
      end)

    case result do
      {:done, answer} -> answer
      _ -> steps_error()
    end
  end

  @doc """
  The models a service offers with a key, from its own list. Newest or most
  relevant first where the service orders them; otherwise by name.
  """
  def list_models(rl, settings) do
    provider = provider!(settings) || raise(AssistantError, message: "Choose a provider", code: "assistant_provider")
    base = JS.or_else(settings["baseUrl"], provider["baseUrl"]) |> String.replace(~r/\/+\z/, "")
    if base == "", do: raise(AssistantError, message: "Enter the service's address first", code: "assistant_address")

    if provider["key"] == "yes" and not JS.truthy?(settings["key"]),
      do:
        raise(AssistantError,
          message: "Enter your #{provider["name"]} key first",
          code: "assistant_key",
          params: [{"provider", provider["name"]}]
        )

    anthropic = provider["protocol"] == "anthropic"

    headers =
      cond do
        anthropic -> [{"x-api-key", settings["key"]}, {"anthropic-version", "2023-06-01"}]
        JS.truthy?(settings["key"]) -> [{"authorization", "Bearer #{settings["key"]}"}]
        true -> []
      end

    url = "#{base}/models#{if anthropic, do: "?limit=100", else: ""}"
    host = host_of(base)

    answer =
      case Runlight.fetch(rl, url, headers: headers, timeout: 20_000) do
        {:ok, answer} ->
          answer

        {:error, _} ->
          raise AssistantError, message: "Could not reach #{host}", code: "unreachable", params: [{"host", host}]
      end

    data =
      case Response.json(answer),
        do: (
          {:ok, d} -> d
          :error -> nil
        )

    unless Response.ok?(answer), do: refused(base, answer.status, data)

    models =
      case JS.prop(data, "data") do
        list when is_list(list) -> list
        _ -> []
      end
      |> Enum.filter(&(is_binary(JS.prop(&1, "id")) and JS.prop(&1, "id") != ""))
      # Gemini lists ids as "models/gemini-...", which its OpenAI-compatible API takes without the prefix.
      |> Enum.map(fn m ->
        id = String.replace(JS.prop(m, "id"), ~r/^models\//, "")
        name = JS.prop(m, "display_name")
        JS.obj(id: id, name: if(is_binary(name), do: name, else: id))
      end)

    if models == [],
      do:
        raise(AssistantError,
          message: "#{host} listed no models. Type the model's name instead.",
          code: "assistant_no_models",
          params: [{"host", host}]
        )

    # Anthropic lists newest first already; others come in no useful order.
    if anthropic, do: models, else: Enum.sort(models, &(Runlight.Collate.compare(&1["id"], &2["id"]) <= 0))
  end
end
