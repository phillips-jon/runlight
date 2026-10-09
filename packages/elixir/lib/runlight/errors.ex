defmodule Runlight.SettingsError do
  @moduledoc "A setting refused, such as a site's domain or the assistant's service, with a code the dashboard says in its own words."
  defexception [:message, :code, params: %{}]
end

defmodule Runlight.LinkError do
  @moduledoc "A link that cannot be made. `code` and `params` let the dashboard say it in its own language."
  defexception [:message, :code, params: %{}]
end

defmodule Runlight.MailError do
  @moduledoc """
  A mail problem to show the person setting it up. `code` and `params` let the
  dashboard say it in its own language; a service's own words travel in
  `params["detail"]`.
  """
  defexception [:message, code: "mail_failed", params: nil]

  @impl true
  def exception(opts) do
    message = Keyword.fetch!(opts, :message)

    %__MODULE__{
      message: message,
      code: Keyword.get(opts, :code, "mail_failed"),
      params: Keyword.get(opts, :params, %{"detail" => message})
    }
  end
end

defmodule Runlight.AssistantError do
  @moduledoc "What went wrong with the assistant, as a code the dashboard says in its own words."
  defexception [:message, :code, params: %{}]
end

defmodule Runlight.ConnectError do
  @moduledoc "Why connecting another install failed, as a code the dashboard says in its own words."
  defexception [:message, :code, params: %{}]
end

defmodule Runlight.ImportError do
  @moduledoc "Why an import stopped, as a code the dashboard says in its own words."
  defexception [:message, :code, params: %{}, status: nil]
end

defmodule Runlight.AccountError do
  @moduledoc "A problem with an account change, to show the person making it, with a code and params."
  defexception [:message, :code, params: %{}]
end

defmodule Runlight.RangeError do
  @moduledoc "JavaScript's RangeError, for the few refusals that carry no code of their own, such as an unknown link."
  defexception [:message]
end

defmodule Runlight.Errors do
  @moduledoc false
  # Internal. Which errors the routes treat as JavaScript's RangeError: the
  # SDK's SettingsError, AccountError, and ConnectError extend it.

  @range [Runlight.SettingsError, Runlight.AccountError, Runlight.ConnectError, Runlight.RangeError]

  @doc "Whether an error is a RangeError in the TypeScript SDK."
  def range?(%{__struct__: s}), do: s in @range
  def range?(_), do: false
end
