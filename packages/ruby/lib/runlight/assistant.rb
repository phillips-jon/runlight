# frozen_string_literal: true

module Runlight
  # The dashboard's assistant: questions about the stats, answered by a model
  # the owner chooses, through the same read-only tools as the MCP server. The
  # model runs on the server, so the key never reaches a browser, and each tool
  # reads the API with the asking person's own access.
  #
  # Two protocols cover the providers: Anthropic's Messages API, and OpenAI's
  # Chat Completions, which OpenAI, Gemini (through its compatible endpoint),
  # OpenRouter, Ollama, LM Studio, and most others speak. Plain HTTP through a
  # fetcher, no SDKs.
  #
  # Settings are { "provider", "model", "baseUrl", "key" }; messages are a list of { "role" ("user" or
  # "assistant"), "content" }; the context (what the person is looking at, so "this week" and "this page" mean
  # what they see) is { "site" => { "id", "name", "timezone" }, "today", "view", "language" }.
  module Assistant
    # Each provider: id, name, protocol ("anthropic" or "openai"), baseUrl (the API's address, filled in for
    # known services and asked for otherwise), model (one to start with, or "" when the person picks one), and
    # key ("yes", "no" for a model on your own machine, or "optional").
    PROVIDERS = [
      { "id" => "anthropic", "name" => "Anthropic (Claude)", "protocol" => "anthropic", "baseUrl" => "https://api.anthropic.com/v1", "model" => "claude-sonnet-5-5", "key" => "yes" },
      { "id" => "openai", "name" => "OpenAI", "protocol" => "openai", "baseUrl" => "https://api.openai.com/v1", "model" => "", "key" => "yes" },
      { "id" => "gemini", "name" => "Google Gemini", "protocol" => "openai", "baseUrl" => "https://generativelanguage.googleapis.com/v1beta/openai", "model" => "", "key" => "yes" },
      { "id" => "openrouter", "name" => "OpenRouter", "protocol" => "openai", "baseUrl" => "https://openrouter.ai/api/v1", "model" => "", "key" => "yes" },
      { "id" => "ollama", "name" => "Ollama", "protocol" => "openai", "baseUrl" => "http://localhost:11434/v1", "model" => "", "key" => "no" },
      { "id" => "lmstudio", "name" => "LM Studio", "protocol" => "openai", "baseUrl" => "http://localhost:1234/v1", "model" => "", "key" => "no" },
      { "id" => "custom", "name" => "Another OpenAI-compatible service", "protocol" => "openai", "baseUrl" => "", "model" => "", "key" => "optional" },
    ].freeze

    MAX_ROUNDS = 8
    # However many rounds a question takes, the answer comes within this long or the assistant stops.
    DEADLINE_MS = 120_000
    MAX_TOKENS = 1500

    TOO_LONG = "That question took too long to answer. Try asking something narrower."

    # Words that only acknowledge an answer, in the dashboard's languages; a message of nothing else gets a reply without the model.
    THANKS = /\A(?:(?:thanks|thank you|thank you so much|thanks a lot|thx|ty|cheers|ok|okay|great|cool|nice|perfect|awesome|got it|good|merci|merci beaucoup|super|parfait|d'accord|gracias|muchas gracias|vale|genial|perfecto|danke|danke schön|vielen dank|prima|alles klar|obrigado|obrigada|valeu|ótimo|beleza)[#{Js::SPACE}!.,]*)+\z/i

    WELCOME = {
      "en" => "You're welcome. Ask me anything else about your stats.",
      "fr" => "Avec plaisir. Demandez-moi autre chose sur vos statistiques.",
      "es" => "De nada. Pregúntame lo que quieras sobre tus estadísticas.",
      "de" => "Gern geschehen. Frag mich gern noch etwas zu deinen Statistiken.",
      "pt" => "De nada. Pergunte o que quiser sobre suas estatísticas.",
    }.freeze

    # ICU's root collation puts these marks in this order, before digits and letters.
    PUNCTUATION = " _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$"
    private_constant :MAX_ROUNDS, :MAX_TOKENS, :TOO_LONG, :THANKS, :WELCOME, :PUNCTUATION

    module_function

    def provider(id)
      PROVIDERS.find { |provider| provider["id"] == id }
    end

    def system_prompt(context)
      site = context["site"]
      "#{Mcp::INSTRUCTIONS}\n\n" \
        "You are the assistant inside this Runlight dashboard. Today is #{context["today"]} in #{site["timezone"]}. " \
        "The person is looking at the site \"#{site["name"]}\" (id #{site["id"]}) for #{context["view"]}. " \
        "Unless they ask about another site or range, use this site and these dates.\n\n" \
        "When a question needs numbers, read them with the tools first and never guess one. Answer in a few short sentences or a short list, " \
        "in plain language, and name the dates you looked at.\n\n" \
        "Rule: answer only the newest message. If it asks nothing new (thanks, a greeting, \"great\", \"that helps\"), reply with one short " \
        "friendly sentence, call no tools, and do not repeat, summarise, or re-check any earlier answer. Only go back to earlier numbers when " \
        "the person asks about them again. Bounce rate is a fraction from 0 to 1 and durations are milliseconds in the tools; give them as a " \
        "percent and in seconds or minutes. Write in the language whose code is \"#{context["language"]}\"."
    end

    # Stops when the question's time is up or the person has left, before more work starts.
    def in_time(deadline, now, cancelled)
      raise AssistantError.new("The question was cancelled.", "assistant_cancelled") if cancelled&.call
      raise AssistantError.new(TOO_LONG, "assistant_slow") if now.call >= deadline
    end

    # The service's own message from an error answer, never the request (it carries the key); "" when there is none.
    def service_message(data)
      error = data.nil? ? UNDEFINED : Js.get(data, "error")
      return error if error.is_a?(String)

      message = error.nil? || error.equal?(UNDEFINED) ? nil : Js.get(error, "message")
      message.is_a?(String) ? message : ""
    end

    def post(fetcher, url, headers, body, deadline, now, cancelled)
      in_time(deadline, now, cancelled)
      left = deadline - now.call
      begin
        answer = fetcher.fetch(url, {
          "method" => "POST",
          "headers" => { "content-type" => "application/json" }.merge(headers),
          "body" => Json.encode(body),
          "timeoutMs" => [90_000, left].min,
        })
      rescue StandardError => e
        host = Http::Url.new(url).host
        raise AssistantError.new("Could not reach #{host}: it took too long to answer", "assistant_timeout", { "host" => host }) if e.is_a?(Http::FetchError) && e.timed_out?

        raise AssistantError.new("Could not reach #{host}: the connection failed", "unreachable", { "host" => host })
      end
      parsed, data = Js.parse_json(answer.text)
      data = nil unless parsed
      unless answer.ok?
        message = service_message(data)
        host = Http::Url.new(url).host
        raise AssistantError.new("#{host}: it answered #{answer.status}", "assistant_status", { "host" => host, "status" => answer.status.to_s }) if message == ""

        detail = Js.cut(message, 300)
        raise AssistantError.new("#{host}: #{detail}", "assistant_refused", { "host" => host, "detail" => detail })
      end
      data.nil? ? {} : data
    end

    # Returns { "text", "error" }.
    def tool_text(name, args, read_api)
      result = Mcp.call_tool({ "name" => name, "arguments" => Js.truthy?(args) && Js.object?(args) ? args : {} }, read_api)
      first = result["content"][0]
      { "text" => first.nil? || first["text"].nil? ? "" : first["text"], "error" => result["isError"] == true }
    rescue StandardError => e
      { "text" => e.message, "error" => true }
    end

    # A short reply to a message that only says thanks or OK, or nil when the message asks something.
    def acknowledgement(text, language)
      plain = Js.trim(Js.scrub(text).gsub(/\p{Extended_Pictographic}|\u{FE0F}/, " "))
      welcome = WELCOME[language] || WELCOME["en"]
      return welcome if plain == "" && Js.trim(text) != ""

      plain.match?(THANKS) ? welcome : nil
    end

    def clock(now)
      now || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
    end

    # Answers the last question in `messages`, calling tools as the model asks. Returns { "reply", "tools" }, the
    # reply and the tools it used. `now` is the clock in milliseconds; `cancelled` says whether the person has left,
    # checked before each request and tool, as the TypeScript's AbortSignal is. Both are callables. `read_api` is
    # as Mcp takes it. Raises AssistantError.
    def chat(settings, messages, context, read_api, fetcher = nil, now = nil, cancelled = nil)
      fetcher ||= Http::NetFetcher.new
      now = clock(now)
      provider = provider(settings["provider"])
      raise AssistantError.new("Choose a provider in Settings, AI Assistant", "assistant_provider") if provider.nil?

      base = (blank?(settings["baseUrl"]) ? provider["baseUrl"] : settings["baseUrl"]).to_s.sub(%r{/+\z}, "")
      raise AssistantError.new("Enter the service's address in Settings, AI Assistant", "assistant_address") if base == ""

      model = blank?(settings["model"]) ? provider["model"] : settings["model"]
      raise AssistantError.new("Enter a model in Settings, AI Assistant", "assistant_model") if model == ""

      key = settings["key"].to_s
      used = []
      # "Thanks!" needs no model, no tools, and certainly not the last answer again.
      last = messages.empty? ? nil : messages[-1]["content"]
      thanks = acknowledgement(last.nil? ? "" : Js.string(last), context["language"])
      return { "reply" => thanks, "tools" => [] } unless thanks.nil?

      deadline = now.call + DEADLINE_MS
      # The last twenty turns, starting with a question (Anthropic refuses a history that opens with an answer),
      # and with unanswered questions in a row (a reply that never came) joined into one.
      recent = messages.last(20)
      recent = recent.drop(1) while !recent.empty? && recent[0]["role"] != "user"
      history = []
      recent.each do |m|
        content = Js.cut(Js.string(m["content"]), 8000)
        if !history.empty? && history[-1]["role"] == m["role"]
          history[-1]["content"] = "#{history[-1]["content"]}\n\n#{content}"
        else
          history << { "role" => m["role"], "content" => content }
        end
      end

      if provider["protocol"] == "anthropic"
        tools = Mcp.tools.map { |t| { "name" => t["name"], "description" => t["description"], "input_schema" => t["inputSchema"] } }
        convo = history.dup
        MAX_ROUNDS.times do
          data = post(
            fetcher,
            "#{base}/messages",
            { "x-api-key" => key, "anthropic-version" => "2023-06-01" },
            { "model" => model, "max_tokens" => MAX_TOKENS, "system" => system_prompt(context), "tools" => tools, "messages" => convo },
            deadline,
            now,
            cancelled,
          )
          blocks = Js.get(data, "content")
          blocks = [] if blocks.nil? || blocks.equal?(UNDEFINED)
          raise unreadable(base) unless blocks.is_a?(Array) && blocks.all?(Hash)

          calls = blocks.select { |b| Js.get(b, "type") == "tool_use" }
          if Js.get(data, "stop_reason") != "tool_use" || calls.empty?
            texts = []
            blocks.each do |b|
              next unless Js.get(b, "type") == "text"

              text = Js.get(b, "text")
              texts << (text.nil? || text.equal?(UNDEFINED) ? "" : Js.string(text))
            end
            return { "reply" => Js.trim(texts.join("\n")), "tools" => used }
          end
          convo << { "role" => "assistant", "content" => blocks }
          results = []
          calls.each do |call|
            # The deadline covers the reading too, however many tools one answer asks for.
            in_time(deadline, now, cancelled)
            name = Js.get(call, "name")
            name = "" if name.nil? || name.equal?(UNDEFINED)
            used << name
            out = tool_text(name, Js.get(call, "input"), read_api)
            result = { "type" => "tool_result", "tool_use_id" => Js.get(call, "id"), "content" => out["text"] }
            result["is_error"] = true if out["error"]
            results << result
          end
          convo << { "role" => "user", "content" => results }
        end
        raise AssistantError.new("The assistant needed too many steps for that question. Try asking something narrower.", "assistant_steps")
      end

      tools = Mcp.tools.map { |t| { "type" => "function", "function" => { "name" => t["name"], "description" => t["description"], "parameters" => t["inputSchema"] } } }
      convo = [{ "role" => "system", "content" => system_prompt(context) }, *history]
      headers = key == "" ? {} : { "authorization" => "Bearer #{key}" }
      MAX_ROUNDS.times do
        # OpenAI's newer models take max_completion_tokens and refuse max_tokens; the other services still take max_tokens.
        limit = provider["id"] == "openai" ? { "max_completion_tokens" => MAX_TOKENS } : { "max_tokens" => MAX_TOKENS }
        data = post(fetcher, "#{base}/chat/completions", headers, { "model" => model }.merge(limit).merge("messages" => convo, "tools" => tools),
                    deadline, now, cancelled)
        message = first_message(data)
        calls = Js.get(message, "tool_calls")
        count = calls.nil? || calls.equal?(UNDEFINED) ? UNDEFINED : Js.get(calls, "length")
        content = Js.get(message, "content")
        unless Js.truthy?(count)
          return { "reply" => Js.trim(content.nil? || content.equal?(UNDEFINED) ? "" : Js.string(content)), "tools" => used }
        end
        raise unreadable(base) unless calls.is_a?(Array) && calls.all? { |call| call.is_a?(Hash) && Js.get(call, "function").is_a?(Hash) }

        convo << { "role" => "assistant", "content" => content.equal?(UNDEFINED) ? nil : content, "tool_calls" => calls }
        calls.each do |call|
          in_time(deadline, now, cancelled)
          function = Js.get(call, "function")
          name = Js.get(function, "name")
          used << (name.equal?(UNDEFINED) ? nil : name)
          given = Js.get(function, "arguments")
          parsed, args = Js.parse_json(Js.truthy?(given) ? Js.string(given) : "{}")
          args = {} unless parsed
          out = tool_text(name, args, read_api)
          convo << { "role" => "tool", "tool_call_id" => Js.get(call, "id"), "content" => out["text"] }
        end
      end
      raise AssistantError.new("The assistant needed too many steps for that question. Try asking something narrower.", "assistant_steps")
    end

    # A service that answered, but not in its protocol's shape.
    def unreadable(url)
      host = Http::Url.new(url).host
      message = "#{host} sent an answer Runlight could not read"
      AssistantError.new(message, "assistant_failed", { "host" => host, "detail" => message })
    end

    # data.choices?.[0]?.message ?? {}
    def first_message(data)
      choices = Js.get(data, "choices")
      return {} if choices.nil? || choices.equal?(UNDEFINED)

      first = Js.get(choices, 0)
      return {} if first.nil? || first.equal?(UNDEFINED)

      message = Js.get(first, "message")
      message.nil? || message.equal?(UNDEFINED) ? {} : message
    end

    # The models a service offers with a key, from its own list: Anthropic's
    # /models, or the /models of an OpenAI-compatible API. Newest or most
    # relevant first where the service orders them; otherwise by name.
    # settings: { "provider", "baseUrl", "key" }. Returns a list of { "id", "name" }. Raises AssistantError.
    def list_models(settings, fetcher = nil)
      fetcher ||= Http::NetFetcher.new
      provider = provider(settings["provider"])
      raise AssistantError.new("Choose a provider", "assistant_provider") if provider.nil?

      base = (blank?(settings["baseUrl"]) ? provider["baseUrl"] : settings["baseUrl"]).to_s.sub(%r{/+\z}, "")
      raise AssistantError.new("Enter the service's address first", "assistant_address") if base == ""

      key = settings["key"].to_s
      if provider["key"] == "yes" && key == ""
        raise AssistantError.new("Enter your #{provider["name"]} key first", "assistant_key", { "provider" => provider["name"] })
      end

      headers = if provider["protocol"] == "anthropic" then { "x-api-key" => key, "anthropic-version" => "2023-06-01" }
                elsif key != "" then { "authorization" => "Bearer #{key}" }
                else {}
                end
      begin
        answer = fetcher.fetch("#{base}/models#{provider["protocol"] == "anthropic" ? "?limit=100" : ""}", { "headers" => headers, "timeoutMs" => 20_000 })
      rescue StandardError
        host = Http::Url.new(base).host
        raise AssistantError.new("Could not reach #{host}", "unreachable", { "host" => host })
      end
      parsed, data = Js.parse_json(answer.text)
      data = nil unless parsed
      unless answer.ok?
        message = service_message(data)
        host = Http::Url.new(base).host
        raise AssistantError.new("#{host}: it answered #{answer.status}", "assistant_status", { "host" => host, "status" => answer.status.to_s }) if message == ""

        detail = Js.cut(message, 300)
        raise AssistantError.new("#{host}: #{detail}", "assistant_refused", { "host" => host, "detail" => detail })
      end
      list = data.nil? ? UNDEFINED : Js.get(data, "data")
      list = [] if list.nil? || list.equal?(UNDEFINED)
      raise unreadable(base) unless list.is_a?(Array)

      models = []
      list.each do |m|
        next unless m.is_a?(Hash)

        id = Js.get(m, "id")
        next if !id.is_a?(String) || id == ""

        # Gemini lists ids as "models/gemini-...", which its OpenAI-compatible API takes without the prefix.
        id = id.sub(%r{\Amodels/}, "")
        display = Js.get(m, "display_name")
        models << { "id" => id, "name" => display.is_a?(String) ? display : id }
      end
      if models.empty?
        host = Http::Url.new(base).host
        raise AssistantError.new("#{host} listed no models. Type the model's name instead.", "assistant_no_models", { "host" => host })
      end
      # Anthropic lists newest first already; others come in no useful order.
      if provider["protocol"] != "anthropic"
        models = models.each_with_index.sort { |(a, i), (b, j)| [locale_compare(a["id"], b["id"]), i] <=> [0, j] }.map(&:first)
      end
      models
    end

    # `value ?? ""` is "".
    def blank?(value)
      value.nil? || value == ""
    end

    # a.localeCompare(b) as Node's ICU orders text by default: letters compared without case or accents first
    # (punctuation and spaces before digits, digits before letters, numbers digit by digit), then accents, then
    # lower case before upper.
    def locale_compare(a, b)
      ka = collation_key(a)
      kb = collation_key(b)
      [0, 1, 2].each do |level|
        order = ka[level] <=> kb[level]
        return order unless order.zero?
      end
      0
    end

    # The three levels of a text's sort key: base characters, accents, and case.
    def collation_key(text)
      primary = []
      secondary = []
      tertiary = []
      Js.scrub(text).unicode_normalize(:nfd).each_char do |c|
        if c.match?(/\p{Mn}/)
          secondary[-1] = (secondary[-1] || []) + [c.ord] unless secondary.empty?
          next
        end
        lower = c.downcase
        mark = PUNCTUATION.index(c)
        primary << if !mark.nil? then [1, mark]
                   elsif c.match?(/\d/) then [2, c.ord]
                   elsif c.match?(/\p{L}/) then [3, lower.ord]
                   else [0, c.ord]
                   end
        secondary << []
        tertiary << (c == lower ? 0 : 1)
      end
      [primary, secondary, tertiary]
    end

    private_class_method :provider, :system_prompt, :in_time, :service_message, :post, :tool_text, :clock, :first_message, :unreadable, :blank?,
                         :locale_compare, :collation_key
  end
end
