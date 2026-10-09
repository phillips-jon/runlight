defmodule Runlight.Mail.Ses do
  @moduledoc false
  # Internal. Amazon SES (API v2) with a hand-rolled Signature Version 4, so
  # there is no AWS SDK to install (the SDK's mail/ses.ts).
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html

  alias Runlight.JS
  alias Runlight.MailError
  alias Runlight.Url

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp sha256(text), do: hex(:crypto.hash(:sha256, text))
  defp hmac(key, text), do: :crypto.mac(:hmac, :sha256, key, text)

  @doc """
  Signs a request; tested against AWS's published example. `input` has
  method, url, body, region, service, access_key_id, secret_access_key, now
  (epoch milliseconds), and headers (`{name, value}` pairs). Answers the
  headers to send, in the SDK's order: the given ones, host, x-amz-date, and
  authorization.
  """
  @spec sign_v4(map()) :: [{String.t(), String.t()}]
  def sign_v4(input) do
    url = Url.new(input.url)
    amz_date = input.now |> JS.iso_string() |> String.replace(~r/[-:]/, "") |> String.replace(~r/\.\d{3}/, "")
    day = binary_part(amz_date, 0, 8)
    payload_hash = sha256(input.body)
    headers = input.headers ++ [{"host", Url.host(url)}, {"x-amz-date", amz_date}]
    names = headers |> Enum.map(&String.downcase(elem(&1, 0))) |> Enum.sort()

    lower =
      Map.new(headers, fn {k, v} -> {String.downcase(k), v |> JS.trim() |> String.replace(~r/\s+/u, " ")} end)

    path =
      url.pathname
      |> String.split("/")
      |> Enum.map_join("/", fn p ->
        JS.encode_uri_component(JS.decode_uri_component(p) || raise(ArgumentError, "URI malformed"))
      end)

    query =
      url
      |> Url.search_params()
      |> Enum.sort_by(&elem(&1, 0), &(JS.compare(&1, &2) <= 0))
      |> Enum.map_join("&", fn {k, v} -> "#{JS.encode_uri_component(k)}=#{JS.encode_uri_component(v)}" end)

    canonical =
      Enum.join(
        [
          input.method,
          if(path == "", do: "/", else: path),
          query,
          Enum.map_join(names, "", &"#{&1}:#{lower[&1]}\n"),
          Enum.join(names, ";"),
          payload_hash
        ],
        "\n"
      )

    scope = "#{day}/#{input.region}/#{input.service}/aws4_request"
    to_sign = Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, sha256(canonical)], "\n")

    key =
      ("AWS4" <> input.secret_access_key)
      |> hmac(day)
      |> hmac(input.region)
      |> hmac(input.service)
      |> hmac("aws4_request")

    signature = hex(hmac(key, to_sign))

    headers ++
      [
        {"authorization",
         "AWS4-HMAC-SHA256 Credential=#{input.access_key_id}/#{scope}, SignedHeaders=#{Enum.join(names, ";")}, Signature=#{signature}"}
      ]
  end

  @doc false
  # Sends one message through SES, `from` already written as an address.
  def send(fetch, config, m, from, now) do
    region = JS.trim(config["region"])

    unless Regex.match?(~r/\A[a-z]{2}(-[a-z]+)+-\d\z/, region),
      do: raise(MailError, message: "That is not an AWS region, like us-east-1", code: "mail_region", params: %{})

    url = "https://email.#{region}.amazonaws.com/v2/email/outbound-emails"

    body =
      JS.stringify(
        JS.obj(
          FromEmailAddress: from,
          Destination: JS.obj(ToAddresses: [m.to]),
          Content:
            JS.obj(
              Simple:
                JS.obj(
                  Subject: JS.obj(Data: m.subject, Charset: "UTF-8"),
                  Body:
                    JS.obj(Html: JS.obj(Data: m.html, Charset: "UTF-8"), Text: JS.obj(Data: m.text, Charset: "UTF-8")),
                  Headers: Enum.map(Map.get(m, :headers) || [], fn {k, v} -> JS.obj(Name: k, Value: v) end)
                )
            )
        )
      )

    headers =
      sign_v4(%{
        method: "POST",
        url: url,
        body: body,
        region: region,
        service: "ses",
        access_key_id: JS.trim(config["accessKeyId"]),
        secret_access_key: JS.trim(config["secretAccessKey"]),
        now: now,
        headers: [{"content-type", "application/json"}]
      })
      |> Enum.reject(fn {k, _} -> k == "host" end)

    case fetch.(url, method: "POST", headers: headers, body: body, timeout: 20_000) do
      {:error, reason} ->
        detail = Runlight.Mail.fetch_message(reason)

        raise MailError,
          message: "Could not reach Amazon SES: #{detail}",
          code: "mail_unreachable",
          params: %{"host" => "Amazon SES", "detail" => detail}

      {:ok, response} when response.status >= 200 and response.status < 300 ->
        :ok

      {:ok, response} ->
        message = Runlight.Mail.service_message(Runlight.Http.Response.text(response))
        suffix = if message != "", do: ": #{message}", else: ""

        raise MailError,
          message: "Amazon SES answered #{response.status}#{suffix}",
          code: "mail_refused",
          params: %{
            "host" => "Amazon SES",
            "detail" => "#{response.status}#{if message != "", do: " #{message}", else: ""}"
          }
    end
  end
end
