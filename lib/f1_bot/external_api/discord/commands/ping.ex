defmodule F1Bot.ExternalApi.Discord.Commands.Ping do
  @moduledoc """
  Slash command `/ping` — reports the bot's latency.

  Latency is derived from the interaction's snowflake timestamp (when Discord
  created it) compared to now, i.e. how long it took us to receive and answer.
  """
  import Bitwise
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common}

  # Discord epoch (2015-01-01) in milliseconds.
  @discord_epoch 1_420_070_400_000

  def handle_interaction(interaction = %Interaction{id: id}) do
    flags = Common.response_flags(interaction)
    locale = Common.locale(interaction)

    created_ms = (id >>> 22) + @discord_epoch
    latency = max(System.os_time(:millisecond) - created_ms, 0)

    Response.make_message(flags, I18n.t(:ping_pong, locale, %{ms: latency}))
    |> Response.send_interaction_response(interaction)
  end
end
