defmodule F1Bot.ExternalApi.Discord.Commands.Common do
  @moduledoc "Shared helpers for slash command handlers."
  alias Nostrum.Struct.Interaction

  @doc "Response is ephemeral unless the `public:true` option was supplied."
  def response_flags(interaction) do
    if public_option?(interaction), do: [], else: [:ephemeral]
  end

  defp public_option?(%Interaction{data: %{options: options}}) when is_list(options) do
    Enum.any?(options, fn o -> o.name == "public" and o.value == true end)
  end

  defp public_option?(_), do: false

  @doc "The invoking user's Discord locale string (or nil)."
  def locale(%Interaction{locale: locale}), do: locale
  def locale(_), do: nil
end
