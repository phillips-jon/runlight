defmodule Runlight.Mail do
  @moduledoc false
  # Internal. Every mail service Runlight can send through, what each needs,
  # and the request each is sent (the SDK's mail/transports.ts), the same
  # URLs, headers, and bodies byte for byte. Every request goes through the
  # instance's fetcher.

  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.MailError
  alias Runlight.SearchParams

  @services [
    [
      id: "ses",
      name: "Amazon SES",
      fields: [
        [name: "region", label: "Region", placeholder: "us-east-1"],
        [name: "accessKeyId", label: "Access key ID"],
        [name: "secretAccessKey", label: "Secret access key", secret: true]
      ]
    ],
    [id: "resend", name: "Resend", fields: [[name: "apiKey", label: "API key", secret: true, placeholder: "re_..."]]],
    [
      id: "postmark",
      name: "Postmark",
      fields: [
        [name: "serverToken", label: "Server API token", secret: true],
        [name: "stream", label: "Message stream", optional: true, placeholder: "outbound"]
      ]
    ],
    [
      id: "sendgrid",
      name: "SendGrid",
      fields: [[name: "apiKey", label: "API key", secret: true, placeholder: "SG...."]]
    ],
    [
      id: "mailgun",
      name: "Mailgun",
      fields: [
        [name: "domain", label: "Sending domain", placeholder: "mg.example.com"],
        [name: "apiKey", label: "API key", secret: true],
        [name: "region", label: "Region", options: ["us", "eu"]]
      ]
    ],
    [
      id: "brevo",
      name: "Brevo",
      fields: [[name: "apiKey", label: "API key", secret: true, placeholder: "xkeysib-..."]]
    ],
    [
      id: "mailjet",
      name: "Mailjet",
      fields: [[name: "apiKey", label: "API key"], [name: "secretKey", label: "Secret key", secret: true]]
    ],
    [
      id: "mailersend",
      name: "MailerSend",
      fields: [[name: "apiKey", label: "API token", secret: true, placeholder: "mlsn...."]]
    ],
    [
      id: "sparkpost",
      name: "SparkPost",
      fields: [
        [name: "apiKey", label: "API key", secret: true],
        [name: "region", label: "Region", options: ["us", "eu"]]
      ]
    ],
    [
      id: "smtp",
      name: "SMTP",
      fields: [
        [name: "host", label: "Host", placeholder: "smtp.example.com"],
        [name: "port", label: "Port", placeholder: "587"],
        [name: "security", label: "Security", options: ["starttls", "tls", "none"]],
        [name: "username", label: "Username", optional: true],
        [name: "password", label: "Password", secret: true, optional: true]
      ]
    ],
    [
      id: "webhook",
      name: "Webhook",
      fields: [
        [name: "url", label: "URL", placeholder: "https://example.com/hooks/mail"],
        [name: "secret", label: "Signing secret", secret: true, optional: true]
      ]
    ]
  ]

  @doc "Every service Runlight can send through, and what each needs, as the dashboard reads them."
  @spec services() :: [Object.t()]
  def services do
    Enum.map(@services, fn s -> JS.obj(id: s[:id], name: s[:name], fields: Enum.map(s[:fields], &JS.obj/1)) end)
  end

  defp field(config, name) do
    case config[name] do
      v when is_binary(v) -> v
      nil -> nil
      :undefined -> nil
      v -> JS.string(v)
    end
  end

  defp address(m) do
    if JS.truthy?(m[:from_name]),
      do: "#{String.replace(m.from_name, ~r/["\\\r\n]/, "")} <#{m.from}>",
      else: m.from
  end

  @doc """
  The error a mail service explains itself with, from its JSON or XML reply,
  and never the raw body: a reply is shown to the dashboard, so an address
  that is not a mail service must not be able to put its page there.
  """
  @spec service_message(String.t()) :: String.t()
  def service_message(reply) do
    case JS.parse(reply) do
      {:ok, parsed} ->
        get = fn key -> JS.prop(parsed, key) end

        [get.("message"), get.("Message"), get.("error"), get.("errors"), get.("ErrorMessage")]
        |> Enum.map(&first/1)
        |> Enum.find("", &(&1 != ""))
        |> JS.slice(0, 200)

      {:error, _} ->
        case Regex.run(~r/<Message>([^<]{1,200})<\/Message>/u, JS.scrub(reply)) do
          [_, m] -> JS.trim(m)
          nil -> ""
        end
    end
  end

  defp first(v) when is_binary(v), do: v
  defp first([head | _]), do: first(head)
  defp first([]), do: ""
  defp first(%Object{} = o), do: first(JS.prop(o, "message"))
  defp first(_), do: ""

  @doc "Checks a config has what its service needs, before anything is saved or sent."
  @spec check_config(Object.t() | map()) :: :ok
  def check_config(config) do
    service = Enum.find(services(), &(&1["id"] == field(config, "service")))
    if service == nil, do: raise(MailError, message: "Pick a mail service", code: "mail_service", params: %{})

    for f <- service["fields"] do
      value = field(config, f["name"])

      if f["optional"] != true and JS.trim(value || "") == "",
        do:
          raise(MailError,
            message: "Enter the #{JS.lower(f["label"])}",
            code: "mail_field",
            params: %{"field" => f["name"]}
          )

      if f["options"] && JS.truthy?(value) && value not in f["options"] do
        options = Enum.join(f["options"], ", ")

        raise MailError,
          message: "#{f["label"]} must be one of #{options}",
          code: "mail_option",
          params: %{"field" => f["name"], "options" => options}
      end
    end

    url = field(config, "url") || ""

    if field(config, "service") == "webhook" and not Regex.match?(~r/^https:\/\//, url) and
         not Regex.match?(~r/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?(\/|$)/, url),
       do: raise(MailError, message: "The webhook URL must use https", code: "mail_https", params: %{})

    if field(config, "service") == "webhook" and Runlight.Url.parse(url) == nil,
      do:
        raise(MailError,
          message: "Enter the webhook's whole URL, like https://example.com/hooks/mail",
          code: "mail_url",
          params: %{}
        )

    # A port a socket can connect to, read with Number() as the SMTP client reads it.
    if field(config, "service") == "smtp" and not port?(field(config, "port")),
      do: raise(MailError, message: "The port must be a whole number from 1 to 65535", code: "mail_port", params: %{})

    :ok
  end

  defp port?(nil), do: false

  defp port?(text) do
    case JS.number(text) do
      n when is_integer(n) -> n >= 1 and n <= 65_535
      n when is_float(n) -> n == Float.round(n) and n >= 1 and n <= 65_535
      _ -> false
    end
  end

  defp host_of(url), do: url |> Runlight.Url.new() |> Runlight.Url.host()

  @doc false
  # One POST. `explains` reads the service's own message from a refusal.
  def post(fetch, url, headers, body, explains \\ true) do
    case fetch.(url, method: "POST", headers: headers, body: body, timeout: 20_000) do
      {:error, reason} ->
        detail = fetch_message(reason)
        host = host_of(url)

        raise MailError,
          message: "Could not reach #{host}: #{detail}",
          code: "mail_unreachable",
          params: [{"host", host}, {"detail", detail}]

      {:ok, response} ->
        if response.status >= 200 and response.status < 300 do
          :ok
        else
          message = if explains, do: service_message(Runlight.Http.Response.text(response)), else: ""
          host = host_of(url)
          suffix = if message != "", do: ": #{message}", else: ""
          detail = "#{response.status}#{if message != "", do: " #{message}", else: ""}"

          raise MailError,
            message: "#{host} answered #{response.status}#{suffix}",
            code: "mail_refused",
            params: [{"host", host}, {"detail", detail}]
        end
    end
  end

  @doc false
  # What fetch's TypeError says when no answer came back.
  def fetch_message(%{__exception__: true} = e), do: Exception.message(e)
  def fetch_message(_), do: "fetch failed"

  defp json(headers), do: [{"content-type", "application/json"} | headers]
  # Basic auth over the UTF-8 bytes, so a key with any character is sent.
  defp basic(user, pass), do: "Basic " <> Base.encode64("#{user}:#{pass}")

  @doc """
  Sends one message through the configured service. The message is
  `%{to, from, from_name, subject, html, text, headers}`, its headers a list
  of `{name, value}`. Raises Runlight.MailError.
  """
  @spec send(Runlight.t(), Object.t() | map(), map()) :: :ok
  def send(rl, config, message) do
    deliver(fn url, opts -> Runlight.fetch(rl, url, opts) end, config, message, now: Runlight.now(rl))
  end

  @doc false
  # send/3 with the fetch and, for tests, the clock and the UUIDs the SMTP message uses.
  def deliver(fetch, config, m, opts \\ []) do
    check_config(config)
    headers = Map.get(m, :headers) || []
    headers_obj = JS.obj(headers)
    c = fn name -> field(config, name) end
    from_name = if JS.truthy?(m[:from_name]), do: m.from_name

    case c.("service") do
      "resend" ->
        post(
          fetch,
          "https://api.resend.com/emails",
          json([{"authorization", "Bearer #{c.("apiKey")}"}]),
          JS.stringify(
            JS.obj(from: address(m), to: [m.to], subject: m.subject, html: m.html, text: m.text, headers: headers_obj)
          )
        )

      "postmark" ->
        post(
          fetch,
          "https://api.postmarkapp.com/email",
          json([{"accept", "application/json"}, {"x-postmark-server-token", c.("serverToken")}]),
          JS.stringify(
            JS.obj(
              From: address(m),
              To: m.to,
              Subject: m.subject,
              HtmlBody: m.html,
              TextBody: m.text,
              MessageStream: JS.or_else(c.("stream"), "outbound"),
              Headers: Enum.map(headers, fn {k, v} -> JS.obj(Name: k, Value: v) end)
            )
          )
        )

      "sendgrid" ->
        post(
          fetch,
          "https://api.sendgrid.com/v3/mail/send",
          json([{"authorization", "Bearer #{c.("apiKey")}"}]),
          JS.stringify(
            JS.obj(
              personalizations: [JS.obj(to: [JS.obj(email: m.to)])],
              from: JS.obj([email: m.from] ++ if(from_name, do: [name: from_name], else: [])),
              subject: m.subject,
              content: [JS.obj(type: "text/plain", value: m.text), JS.obj(type: "text/html", value: m.html)],
              headers: headers_obj
            )
          )
        )

      "mailgun" ->
        form =
          SearchParams.new([
            {"from", address(m)},
            {"to", m.to},
            {"subject", m.subject},
            {"html", m.html},
            {"text", m.text}
          ])

        form = Enum.reduce(headers, form, fn {k, v}, form -> SearchParams.set(form, "h:#{k}", v) end)
        host = if c.("region") == "eu", do: "api.eu.mailgun.net", else: "api.mailgun.net"

        post(
          fetch,
          "https://#{host}/v3/#{JS.encode_uri_component(c.("domain"))}/messages",
          [{"authorization", basic("api", c.("apiKey"))}, {"content-type", "application/x-www-form-urlencoded"}],
          SearchParams.to_string(form)
        )

      "brevo" ->
        post(
          fetch,
          "https://api.brevo.com/v3/smtp/email",
          json([{"api-key", c.("apiKey")}, {"accept", "application/json"}]),
          JS.stringify(
            JS.obj(
              sender: JS.obj([email: m.from] ++ if(from_name, do: [name: from_name], else: [])),
              to: [JS.obj(email: m.to)],
              subject: m.subject,
              htmlContent: m.html,
              textContent: m.text,
              headers: headers_obj
            )
          )
        )

      "mailjet" ->
        post(
          fetch,
          "https://api.mailjet.com/v3.1/send",
          json([{"authorization", basic(c.("apiKey"), c.("secretKey"))}]),
          JS.stringify(
            JS.obj(
              Messages: [
                JS.obj(
                  From: JS.obj([Email: m.from] ++ if(from_name, do: [Name: from_name], else: [])),
                  To: [JS.obj(Email: m.to)],
                  Subject: m.subject,
                  TextPart: m.text,
                  HTMLPart: m.html,
                  Headers: headers_obj
                )
              ]
            )
          )
        )

      "mailersend" ->
        post(
          fetch,
          "https://api.mailersend.com/v1/email",
          json([{"authorization", "Bearer #{c.("apiKey")}"}]),
          JS.stringify(
            JS.obj(
              [
                from: JS.obj([email: m.from] ++ if(from_name, do: [name: from_name], else: [])),
                to: [JS.obj(email: m.to)],
                subject: m.subject,
                html: m.html,
                text: m.text
              ] ++
                if(headers != [],
                  do: [headers: Enum.map(headers, fn {k, v} -> JS.obj(name: k, value: v) end)],
                  else: []
                )
            )
          )
        )

      "sparkpost" ->
        host = if c.("region") == "eu", do: "api.eu.sparkpost.com", else: "api.sparkpost.com"

        post(
          fetch,
          "https://#{host}/api/v1/transmissions",
          json([{"authorization", c.("apiKey")}]),
          JS.stringify(
            JS.obj(
              recipients: [JS.obj(address: JS.obj(email: m.to))],
              content:
                JS.obj(
                  from: if(from_name, do: JS.obj(email: m.from, name: from_name), else: m.from),
                  subject: m.subject,
                  html: m.html,
                  text: m.text,
                  headers: headers_obj
                )
            )
          )
        )

      "ses" ->
        Runlight.Mail.Ses.send(fetch, config, m, address(m), Keyword.get(opts, :now, System.os_time(:millisecond)))

      "smtp" ->
        Runlight.Mail.Smtp.send(config, m, address(m), 60_000, opts)

      "webhook" ->
        body =
          JS.stringify(
            JS.obj(
              to: m.to,
              from: m.from,
              fromName: m[:from_name] || "",
              subject: m.subject,
              html: m.html,
              text: m.text,
              headers: headers_obj
            )
          )

        secret = c.("secret")

        signature =
          if JS.truthy?(secret),
            do: [{"x-runlight-signature", "sha256=" <> Runlight.Hash.hmac(secret, body)}],
            else: []

        # A webhook can be any address, so only its status comes back.
        post(fetch, c.("url"), json(signature), body, false)

      other ->
        raise MailError, message: ~s(Unknown mail service "#{other}"), code: "mail_service", params: %{}
    end
  end
end
