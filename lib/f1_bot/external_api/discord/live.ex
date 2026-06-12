defmodule F1Bot.ExternalApi.Discord.Live do
  @moduledoc ""
  require Logger
  @behaviour F1Bot.ExternalApi.Discord

  @impl F1Bot.ExternalApi.Discord
  def post_message(message_or_tuple) do
    {type, payload} =
      case message_or_tuple do
        {:embed, embed} -> {:default, {:embed, embed}}
        {:embed, type, embed} -> {type, {:embed, embed}}
        message when is_binary(message) -> {:default, message}
        {type, message} -> {type, message}
      end

    channel_ids =
      case type do
        :radio -> F1Bot.get_env(:discord_channel_ids_radios, [])
        _ -> F1Bot.get_env(:discord_channel_ids_messages, [])
      end

    Logger.info("[DISCORD] #{describe(payload)} (to channels: #{inspect(channel_ids)})")

    for channel_id <- channel_ids do
      result =
        case payload do
          {:embed, embed} -> Nostrum.Api.create_message(channel_id, embeds: [embed])
          content -> Nostrum.Api.create_message(channel_id, content)
        end

      case result do
        {:ok, _result} -> :ok
        {:error, err} -> Logger.error("Failed to post Discord message: #{inspect(err)}")
      end
    end

    :ok
  end

  defp describe({:embed, embed}), do: "[embed] #{embed[:title]}"
  defp describe(content), do: content
end
