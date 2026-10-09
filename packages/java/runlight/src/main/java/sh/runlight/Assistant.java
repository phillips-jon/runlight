package sh.runlight;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.function.LongSupplier;
import java.util.regex.Pattern;
import sh.runlight.http.FetchError;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Headers;
import sh.runlight.http.Response;
import sh.runlight.http.Url;

/**
 * The dashboard's assistant: questions about the stats, answered by a model the owner chooses,
 * through the same read-only tools as the MCP server. The model runs on the server, so the key
 * never reaches a browser, and each tool reads the API with the asking person's own access.
 *
 * <p>Two protocols cover the providers: Anthropic's Messages API, and OpenAI's Chat Completions,
 * which OpenAI, Gemini (through its compatible endpoint), OpenRouter, Ollama, LM Studio, and most
 * others speak. Plain HTTP through a {@link Fetcher}, no SDKs.
 *
 * <p>Settings are a map of provider, model, baseUrl, and key; messages are maps of role ("user" or
 * "assistant") and content; the context (what the person is looking at, so "this week" and "this
 * page" mean what they see) is a map of site (id, name, timezone), today, view, and language.
 */
public final class Assistant {
  private Assistant() {}

  private static Map<String, Object> provider(
      String id, String name, String protocol, String baseUrl, String model, String key) {
    return Map.copyOf(
        Json.object(
            "id",
            id,
            "name",
            name,
            "protocol",
            protocol,
            "baseUrl",
            baseUrl,
            "model",
            model,
            "key",
            key));
  }

  /**
   * Each provider: id, name, protocol ("anthropic" or "openai"), baseUrl (the API's address, filled
   * in for known services and asked for otherwise), model (one to start with, or "" when the person
   * picks one), and key ("yes", "no" for a model on your own machine, or "optional").
   */
  public static final List<Map<String, Object>> PROVIDERS =
      List.of(
          provider(
              "anthropic",
              "Anthropic (Claude)",
              "anthropic",
              "https://api.anthropic.com/v1",
              "claude-sonnet-5-5",
              "yes"),
          provider("openai", "OpenAI", "openai", "https://api.openai.com/v1", "", "yes"),
          provider(
              "gemini",
              "Google Gemini",
              "openai",
              "https://generativelanguage.googleapis.com/v1beta/openai",
              "",
              "yes"),
          provider("openrouter", "OpenRouter", "openai", "https://openrouter.ai/api/v1", "", "yes"),
          provider("ollama", "Ollama", "openai", "http://localhost:11434/v1", "", "no"),
          provider("lmstudio", "LM Studio", "openai", "http://localhost:1234/v1", "", "no"),
          provider("custom", "Another OpenAI-compatible service", "openai", "", "", "optional"));

  private static final int MAX_ROUNDS = 8;

  /**
   * However many rounds a question takes, the answer comes within this long or the assistant stops.
   */
  public static final long DEADLINE_MS = 120_000;

  private static final long MAX_TOKENS = 1500;

  private static final String TOO_LONG =
      "That question took too long to answer. Try asking something narrower.";

  private static final String STEPS =
      "The assistant needed too many steps for that question. Try asking something narrower.";

  /**
   * Words that only acknowledge an answer, in the dashboard's languages; a message of nothing else
   * gets a reply without the model.
   */
  private static final Pattern THANKS =
      Pattern.compile(
          "^(?:(?:thanks|thank you|thank you so much|thanks a lot|thx|ty|cheers|ok|okay|great|cool"
              + "|nice|perfect|awesome|got it|good|merci|merci beaucoup|super|parfait|d'accord"
              + "|gracias|muchas gracias|vale|genial|perfecto|danke|danke schön|vielen dank|prima"
              + "|alles klar|obrigado|obrigada|valeu|ótimo|beleza)["
              + Js.SPACE
              + "!.,]*)+\\z",
          Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE);

  private static final Pattern PICTOGRAPHIC =
      Pattern.compile("\\p{IsExtended_Pictographic}|\\x{FE0F}");

  private static final Map<String, String> WELCOME =
      Map.of(
          "en", "You're welcome. Ask me anything else about your stats.",
          "fr", "Avec plaisir. Demandez-moi autre chose sur vos statistiques.",
          "es", "De nada. Pregúntame lo que quieras sobre tus estadísticas.",
          "de", "Gern geschehen. Frag mich gern noch etwas zu deinen Statistiken.",
          "pt", "De nada. Pergunte o que quiser sobre suas estatísticas.");

  private static Map<String, Object> provider(Object id) {
    for (Map<String, Object> p : PROVIDERS) {
      if (p.get("id").equals(id)) {
        return p;
      }
    }
    return null;
  }

  private static String system(Map<String, Object> context) {
    Object site = Js.get(context, "site");
    return Mcp.INSTRUCTIONS
        + "\n\nYou are the assistant inside this Runlight dashboard. Today is "
        + Js.string(Js.get(context, "today"))
        + " in "
        + Js.string(Js.get(site, "timezone"))
        + ". The person is looking at the site \""
        + Js.string(Js.get(site, "name"))
        + "\" (id "
        + Js.string(Js.get(site, "id"))
        + ") for "
        + Js.string(Js.get(context, "view"))
        + ". Unless they ask about another site or range, use this site and these dates.\n\n"
        + "When a question needs numbers, read them with the tools first and never guess one."
        + " Answer in a few short sentences or a short list, in plain language, and name the dates"
        + " you looked at.\n\n"
        + "Rule: answer only the newest message. If it asks nothing new (thanks, a greeting,"
        + " \"great\", \"that helps\"), reply with one short friendly sentence, call no tools, and"
        + " do not repeat, summarise, or re-check any earlier answer. Only go back to earlier"
        + " numbers when the person asks about them again. Bounce rate is a fraction from 0 to 1"
        + " and durations are milliseconds in the tools; give them as a percent and in seconds or"
        + " minutes. Write in the language whose code is \""
        + Js.string(Js.get(context, "language"))
        + "\".";
  }

  /** Stops when the question's time is up or the person has left, before more work starts. */
  private static void inTime(long deadline, LongSupplier now, BooleanSupplier cancelled) {
    if (cancelled != null && cancelled.getAsBoolean()) {
      throw new AssistantError("The question was cancelled.", "assistant_cancelled");
    }
    if (now.getAsLong() >= deadline) {
      throw new AssistantError(TOO_LONG, "assistant_slow");
    }
  }

  /**
   * The service's own message from an error answer, never the request (it carries the key); "" when
   * there is none.
   */
  private static String serviceMessage(Object data) {
    Object error = data == null ? Json.UNDEFINED : Js.get(data, "error");
    if (error instanceof String s) {
      return s;
    }
    Object message = error == null || error == Json.UNDEFINED ? null : Js.get(error, "message");
    return message instanceof String s ? s : "";
  }

  /** Throws the error for an answer that is not ok. */
  private static AssistantError refused(Response answer, Object data, String host) {
    String message = serviceMessage(data);
    if (message.isEmpty()) {
      return new AssistantError(
          host + ": it answered " + answer.status(),
          "assistant_status",
          Json.object("host", host, "status", Integer.toString(answer.status())));
    }
    String detail = Js.slice(message, 0, 300);
    return new AssistantError(
        host + ": " + detail, "assistant_refused", Json.object("host", host, "detail", detail));
  }

  private static Object parse(Response answer) {
    Json.Parsed parsed = Json.tryParse(answer.text());
    return parsed.ok() ? parsed.value() : null;
  }

  private static Object post(
      Fetcher fetcher,
      String url,
      Headers headers,
      Object body,
      long deadline,
      LongSupplier now,
      BooleanSupplier cancelled) {
    inTime(deadline, now, cancelled);
    long left = deadline - now.getAsLong();
    Headers all = new Headers();
    all.set("content-type", "application/json");
    for (Map.Entry<String, List<String>> e : headers.all().entrySet()) {
      all.set(e.getKey(), String.join(", ", e.getValue()));
    }
    Response answer;
    try {
      answer =
          fetcher.fetch(
              url,
              new FetchInit()
                  .method("POST")
                  .headers(all)
                  .body(Json.stringify(body))
                  .timeoutMs(Math.min(90_000, left)));
    } catch (RuntimeException error) {
      String host = new Url(url).host();
      throw error instanceof FetchError f && f.timedOut()
          ? new AssistantError(
              "Could not reach " + host + ": it took too long to answer",
              "assistant_timeout",
              Json.object("host", host))
          : new AssistantError(
              "Could not reach " + host + ": the connection failed",
              "unreachable",
              Json.object("host", host));
    }
    Object data = parse(answer);
    if (!answer.ok()) {
      throw refused(answer, data, new Url(url).host());
    }
    return data == null ? new LinkedHashMap<String, Object>() : data;
  }

  private record ToolText(String text, boolean error) {}

  private static ToolText toolText(Object name, Object args, Mcp.ApiRead readApi) {
    try {
      Map<String, Object> result =
          Mcp.callTool(
              Json.object(
                  "name",
                  name,
                  "arguments",
                  Js.truthy(args) && Js.isObject(args) ? args : new LinkedHashMap<>()),
              readApi);
      Object text = Js.get(Js.get(result.get("content"), "0"), "text");
      return new ToolText(
          text == null || text == Json.UNDEFINED ? "" : (String) text,
          Boolean.TRUE.equals(result.get("isError")));
    } catch (RuntimeException error) {
      return new ToolText(error.getMessage(), true);
    }
  }

  /**
   * A short reply to a message that only says thanks or OK, or null when the message asks
   * something.
   */
  public static String acknowledgement(String text, String language) {
    String plain = Js.trim(PICTOGRAPHIC.matcher(text).replaceAll(" "));
    String welcome = WELCOME.getOrDefault(language, WELCOME.get("en"));
    if (plain.isEmpty() && !Js.trim(text).isEmpty()) {
      return welcome;
    }
    return THANKS.matcher(plain).find() ? welcome : null;
  }

  /** settings[key] || fallback, as text. */
  private static String setting(Map<String, Object> settings, String key, Object fallback) {
    Object value = settings.get(key);
    return Js.string(Js.truthy(value) ? value : fallback);
  }

  /** The API's address: the one in settings or the provider's, without trailing slashes. */
  private static String base(Map<String, Object> settings, Map<String, Object> provider) {
    return setting(settings, "baseUrl", provider.get("baseUrl")).replaceFirst("/+\\z", "");
  }

  private static String key(Map<String, Object> settings) {
    Object key = settings.get("key");
    return key == null || key == Json.UNDEFINED ? "" : Js.string(key);
  }

  /** Answers on the wall clock, with nothing to say the person has left. */
  public static Map<String, Object> chat(
      Map<String, Object> settings,
      List<Map<String, Object>> messages,
      Map<String, Object> context,
      Mcp.ApiRead readApi,
      Fetcher fetcher) {
    return chat(settings, messages, context, readApi, fetcher, null, null);
  }

  /**
   * Answers the last question in {@code messages}, calling tools as the model asks. Returns the
   * reply and the tools it used, as a map of reply and tools. {@code now} is the clock in
   * milliseconds (the wall clock when null); {@code cancelled} says whether the person has left,
   * checked before each request and tool, as the TypeScript's AbortSignal is.
   *
   * @throws AssistantError when the question cannot be answered
   */
  public static Map<String, Object> chat(
      Map<String, Object> settings,
      List<Map<String, Object>> messages,
      Map<String, Object> context,
      Mcp.ApiRead readApi,
      Fetcher fetcher,
      LongSupplier now,
      BooleanSupplier cancelled) {
    LongSupplier clock = now != null ? now : System::currentTimeMillis;
    Map<String, Object> provider = provider(settings.get("provider"));
    if (provider == null) {
      throw new AssistantError("Choose a provider in Settings, AI Assistant", "assistant_provider");
    }
    String base = base(settings, provider);
    if (base.isEmpty()) {
      throw new AssistantError(
          "Enter the service's address in Settings, AI Assistant", "assistant_address");
    }
    String model = setting(settings, "model", provider.get("model"));
    if (model.isEmpty()) {
      throw new AssistantError("Enter a model in Settings, AI Assistant", "assistant_model");
    }
    String key = key(settings);
    List<Object> used = new ArrayList<>();
    // "Thanks!" needs no model, no tools, and certainly not the last answer again.
    Object last = messages.isEmpty() ? null : messages.get(messages.size() - 1).get("content");
    String thanks =
        acknowledgement(
            last == null || last == Json.UNDEFINED ? "" : Js.string(last),
            Js.string(context.get("language")));
    if (thanks != null) {
      return Json.object("reply", thanks, "tools", new ArrayList<>());
    }
    long deadline = clock.getAsLong() + DEADLINE_MS;
    // The last twenty turns, starting with a question (Anthropic refuses a history that opens with
    // an answer), and with unanswered questions in a row (a reply that never came) joined into one.
    List<Map<String, Object>> recent =
        new ArrayList<>(messages.subList(Math.max(0, messages.size() - 20), messages.size()));
    while (!recent.isEmpty() && !"user".equals(recent.get(0).get("role"))) {
      recent.remove(0);
    }
    List<Object> history = new ArrayList<>();
    for (Map<String, Object> m : recent) {
      String content = Js.slice(Js.string(m.get("content")), 0, 8000);
      Map<String, Object> previous =
          history.isEmpty() ? null : Js.map(history.get(history.size() - 1));
      if (previous != null && Js.same(previous.get("role"), m.get("role"))) {
        previous.put("content", previous.get("content") + "\n\n" + content);
      } else {
        history.add(Json.object("role", m.get("role"), "content", content));
      }
    }

    if (provider.get("protocol").equals("anthropic")) {
      List<Object> tools = new ArrayList<>();
      for (Mcp.Tool t : Mcp.TOOLS) {
        tools.add(
            Json.object(
                "name", t.name(), "description", t.description(), "input_schema", t.inputSchema()));
      }
      List<Object> convo = history;
      Headers headers = Headers.of("x-api-key", key, "anthropic-version", "2023-06-01");
      for (int round = 0; round < MAX_ROUNDS; round++) {
        Object data =
            post(
                fetcher,
                base + "/messages",
                headers,
                Json.object(
                    "model",
                    model,
                    "max_tokens",
                    MAX_TOKENS,
                    "system",
                    system(context),
                    "tools",
                    tools,
                    "messages",
                    convo),
                deadline,
                clock,
                cancelled);
        Object content = Js.get(data, "content");
        if (content == null || content == Json.UNDEFINED) {
          content = new ArrayList<>();
        }
        if (!(content instanceof List<?> blocks)) {
          throw new IllegalArgumentException("blocks.filter is not a function");
        }
        List<Object> calls = new ArrayList<>();
        for (Object b : blocks) {
          if ("tool_use".equals(Mcp.prop(b, "type"))) {
            calls.add(b);
          }
        }
        if (!"tool_use".equals(Js.get(data, "stop_reason")) || calls.isEmpty()) {
          List<String> texts = new ArrayList<>();
          for (Object b : blocks) {
            if ("text".equals(Js.get(b, "type"))) {
              Object text = Js.get(b, "text");
              texts.add(text == null || text == Json.UNDEFINED ? "" : Js.string(text));
            }
          }
          return Json.object("reply", Js.trim(String.join("\n", texts)), "tools", used);
        }
        convo.add(Json.object("role", "assistant", "content", blocks));
        List<Object> results = new ArrayList<>();
        for (Object call : calls) {
          // The deadline covers the reading too, however many tools one answer asks for.
          inTime(deadline, clock, cancelled);
          Object name = Js.get(call, "name");
          if (name == null || name == Json.UNDEFINED) {
            name = "";
          }
          used.add(name);
          ToolText out = toolText(name, Js.get(call, "input"), readApi);
          Map<String, Object> result =
              Json.object(
                  "type", "tool_result", "tool_use_id", Js.get(call, "id"), "content", out.text());
          if (out.error()) {
            result.put("is_error", true);
          }
          results.add(result);
        }
        convo.add(Json.object("role", "user", "content", results));
      }
      throw new AssistantError(STEPS, "assistant_steps");
    }

    List<Object> tools = new ArrayList<>();
    for (Mcp.Tool t : Mcp.TOOLS) {
      tools.add(
          Json.object(
              "type",
              "function",
              "function",
              Json.object(
                  "name",
                  t.name(),
                  "description",
                  t.description(),
                  "parameters",
                  t.inputSchema())));
    }
    List<Object> convo = new ArrayList<>();
    convo.add(Json.object("role", "system", "content", system(context)));
    convo.addAll(history);
    Headers headers = key.isEmpty() ? new Headers() : Headers.of("authorization", "Bearer " + key);
    for (int round = 0; round < MAX_ROUNDS; round++) {
      // OpenAI's newer models take max_completion_tokens and refuse max_tokens; the other services
      // still take max_tokens.
      Map<String, Object> body = Json.object("model", model);
      body.put(
          provider.get("id").equals("openai") ? "max_completion_tokens" : "max_tokens", MAX_TOKENS);
      body.put("messages", convo);
      body.put("tools", tools);
      Object data =
          post(fetcher, base + "/chat/completions", headers, body, deadline, clock, cancelled);
      Object message = firstMessage(data);
      Object calls = Js.get(message, "tool_calls");
      Object count =
          calls == null || calls == Json.UNDEFINED ? Json.UNDEFINED : Js.get(calls, "length");
      Object content = Js.get(message, "content");
      if (!Js.truthy(count)) {
        return Json.object(
            "reply",
            Js.trim(content == null || content == Json.UNDEFINED ? "" : Js.string(content)),
            "tools",
            used);
      }
      if (!(calls instanceof List<?> list)) {
        throw new IllegalArgumentException("message.tool_calls is not iterable");
      }
      convo.add(
          Json.object(
              "role",
              "assistant",
              "content",
              content == Json.UNDEFINED ? null : content,
              "tool_calls",
              list));
      for (Object call : list) {
        inTime(deadline, clock, cancelled);
        Object function = Mcp.prop(call, "function");
        Object name = Mcp.prop(function, "name");
        used.add(name == Json.UNDEFINED ? null : name);
        Object given = Js.get(function, "arguments");
        Json.Parsed parsed = Json.tryParse(Js.truthy(given) ? Js.string(given) : "{}");
        Object args = parsed.ok() ? parsed.value() : new LinkedHashMap<String, Object>();
        ToolText out = toolText(name, args, readApi);
        convo.add(
            Json.object("role", "tool", "tool_call_id", Js.get(call, "id"), "content", out.text()));
      }
    }
    throw new AssistantError(STEPS, "assistant_steps");
  }

  /** data.choices?.[0]?.message ?? {}. */
  private static Object firstMessage(Object data) {
    Object choices = Js.get(data, "choices");
    if (choices == null || choices == Json.UNDEFINED) {
      return new LinkedHashMap<String, Object>();
    }
    Object first = Js.get(choices, "0");
    if (first == null || first == Json.UNDEFINED) {
      return new LinkedHashMap<String, Object>();
    }
    Object message = Js.get(first, "message");
    return message == null || message == Json.UNDEFINED
        ? new LinkedHashMap<String, Object>()
        : message;
  }

  /**
   * The models a service offers with a key, from its own list: Anthropic's /models, or the /models
   * of an OpenAI-compatible API. Newest or most relevant first where the service orders them;
   * otherwise by name. Each is a map of id and name.
   *
   * @param settings provider, baseUrl, and key
   * @throws AssistantError when the service cannot be asked or lists none
   */
  public static List<Map<String, Object>> listModels(
      Map<String, Object> settings, Fetcher fetcher) {
    Map<String, Object> provider = provider(settings.get("provider"));
    if (provider == null) {
      throw new AssistantError("Choose a provider", "assistant_provider");
    }
    String base = base(settings, provider);
    if (base.isEmpty()) {
      throw new AssistantError("Enter the service's address first", "assistant_address");
    }
    String key = key(settings);
    String name = (String) provider.get("name");
    if (provider.get("key").equals("yes") && key.isEmpty()) {
      throw new AssistantError(
          "Enter your " + name + " key first", "assistant_key", Json.object("provider", name));
    }
    boolean anthropic = provider.get("protocol").equals("anthropic");
    Headers headers =
        anthropic
            ? Headers.of("x-api-key", key, "anthropic-version", "2023-06-01")
            : key.isEmpty() ? new Headers() : Headers.of("authorization", "Bearer " + key);
    Response answer;
    try {
      answer =
          fetcher.fetch(
              base + "/models" + (anthropic ? "?limit=100" : ""),
              new FetchInit().headers(headers).timeoutMs(20_000));
    } catch (RuntimeException error) {
      String host = new Url(base).host();
      throw new AssistantError("Could not reach " + host, "unreachable", Json.object("host", host));
    }
    Object data = parse(answer);
    if (!answer.ok()) {
      throw refused(answer, data, new Url(base).host());
    }
    Object list = data == null ? Json.UNDEFINED : Js.get(data, "data");
    if (list == null || list == Json.UNDEFINED) {
      list = List.of();
    }
    if (!(list instanceof List<?> items)) {
      throw new IllegalArgumentException("data.data.filter is not a function");
    }
    List<Map<String, Object>> models = new ArrayList<>();
    for (Object m : items) {
      if (!(Mcp.prop(m, "id") instanceof String id) || id.isEmpty()) {
        continue;
      }
      // Gemini lists ids as "models/gemini-...", which its OpenAI-compatible API takes without the
      // prefix.
      String bare = id.startsWith("models/") ? id.substring(7) : id;
      Object display = Js.get(m, "display_name");
      models.add(Json.object("id", bare, "name", display instanceof String s ? s : bare));
    }
    if (models.isEmpty()) {
      String host = new Url(base).host();
      throw new AssistantError(
          host + " listed no models. Type the model's name instead.",
          "assistant_no_models",
          Json.object("host", host));
    }
    // Anthropic lists newest first already; others come in no useful order.
    if (!anthropic) {
      models.sort((a, b) -> localeCompare((String) a.get("id"), (String) b.get("id")));
    }
    return models;
  }

  /**
   * Every printable ASCII character, the ASCII spaces, and U+0085 in the order Node's localeCompare
   * (ICU's root collation) sorts them; a letter's two cases share a place, the small one first.
   */
  private static final String ORDER =
      "\t\n\u000B\f\r\u0085 _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrRsStTuUvVwWxXyYzZ";

  /** The combining marks Latin letters decompose to, in ICU's secondary order. */
  private static final String MARKS =
      "\u0301\u0300\u0306\u0302\u030C\u030A\u0308\u030B\u0303\u0307\u0327\u0328\u0304"
          + "\u0309\u030F\u0311\u031B\u0323\u0324\u0325\u0326\u032D\u032E\u0330\u0331";

  /** The primary weight of each character in ORDER, by code point; zero for any other. */
  private static final int[] PRIMARIES = new int[0x86];

  private static final int COMMON = 1;
  private static final int UPPER = 2;

  /** The tertiary weight of U+00A0, a space that sorts after the plain one. */
  private static final int NO_BREAK = 3;

  /** The first primary weight past those in ORDER, for characters ranked by code point. */
  private static final int BEYOND = 1000;

  static {
    int weight = 0;
    for (int i = 0; i < ORDER.length(); i++) {
      char c = ORDER.charAt(i);
      // A capital shares the small letter's weight.
      if (c < 'A' || c > 'Z') {
        weight++;
      }
      PRIMARIES[c] = weight;
    }
  }

  private static int primary(int cp) {
    return cp < PRIMARIES.length ? PRIMARIES[cp] : 0;
  }

  /** A collation element: a primary weight (the letter), a secondary (its marks), a tertiary. */
  private static int[] letter(int c) {
    return new int[] {primary(c), COMMON, c >= 'A' && c <= 'Z' ? UPPER : COMMON};
  }

  /**
   * The collation elements of a string, each {primary, secondary, tertiary}; zero is a weight the
   * level skips. The string is decomposed first, as ICU compares canonically equivalent strings as
   * equal, so a Latin letter with marks is its ASCII letter and then its marks in canonical order.
   */
  private static List<int[]> elements(String text) {
    List<int[]> out = new ArrayList<>();
    Normalizer.normalize(text, Normalizer.Form.NFD)
        .codePoints()
        .forEach(
            cp -> {
              int mark = cp < 0x10000 ? MARKS.indexOf((char) cp) + 1 : 0;
              if (primary(cp) != 0) {
                out.add(letter(cp));
              } else if (cp == 0xA0) {
                out.add(new int[] {primary(' '), COMMON, NO_BREAK});
              } else if (cp < 0x20 || cp >= 0x7F && cp < 0xA0) {
                // Controls are ignored altogether.
              } else if (mark != 0) {
                out.add(new int[] {0, COMMON + mark, COMMON});
              } else {
                out.add(new int[] {BEYOND + cp, COMMON, COMMON});
              }
            });
    return out;
  }

  /**
   * a.localeCompare(b) as Node has it, with ICU's root collation: letters before their marks before
   * their case, level by level, so "e" before "\u00E9" before "f" and "ab" before "aB" before "Ab".
   * It is exact for ASCII and for Latin letters whose marks decompose; any other character sorts
   * after z by its code point, where ICU has an order of its own. The Go port's weights, checked
   * against Node on the pairs of the Java and Go ports' collation.json.
   */
  static int localeCompare(String a, String b) {
    List<int[]> x = elements(a);
    List<int[]> y = elements(b);
    for (int level = 0; level < 3; level++) {
      int order = java.util.Arrays.compare(weights(x, level), weights(y, level));
      if (order != 0) {
        return Integer.signum(order);
      }
    }
    return 0;
  }

  private static int[] weights(List<int[]> elements, int level) {
    return elements.stream().mapToInt(e -> e[level]).filter(w -> w != 0).toArray();
  }
}
