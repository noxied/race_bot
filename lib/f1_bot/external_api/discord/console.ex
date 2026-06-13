defmodule F1Bot.ExternalApi.Discord.Console do
  @moduledoc ""
  @behaviour F1Bot.ExternalApi.Discord
  require Logger

  def post_message(message_or_tuple) do
    message =
      case message_or_tuple do
        {:embed, embed} -> "[embed] #{embed[:title]} - #{embed[:description]}"
        {:embed, _type, embed} -> "[embed] #{embed[:title]} - #{embed[:description]}"
        {_type, message} -> message
        message -> message
      end

    Logger.info("[DISCORD] #{message}")
  end
end
