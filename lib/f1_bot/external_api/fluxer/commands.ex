defmodule F1Bot.ExternalApi.Fluxer.Commands do
  @moduledoc """
  Parses `!` prefix commands from Fluxer `MESSAGE_CREATE` events and replies in the
  same channel over REST. Fluxer has no slash commands, so this is the equivalent
  of the Discord slash command layer.
  """
  require Logger

  alias F1Bot.ExternalApi.Fluxer
  alias F1Bot.ExternalApi.Discord.I18n

  @prefix "!"

  def handle_message(%{"content" => content, "channel_id" => channel_id, "author" => author})
      when is_binary(content) do
    cond do
      author["bot"] == true ->
        :ok

      not String.starts_with?(content, @prefix) ->
        :ok

      true ->
        [raw_cmd | args] = content |> String.trim() |> String.split(~r/\s+/, trim: true)
        cmd = raw_cmd |> String.trim_leading(@prefix) |> String.downcase()
        dispatch(cmd, args, channel_id)
    end
  end

  def handle_message(_), do: :ok

  # ---- dispatch -----------------------------------------------------------

  defp dispatch("ping", _args, ch), do: reply(ch, %{content: "🏓 Pong!"})
  defp dispatch("help", _args, ch), do: reply(ch, %{embeds: [help_embed()]})
  defp dispatch(_unknown, _args, _ch), do: :ok

  # ---- helpers ------------------------------------------------------------

  defp reply(channel_id, body) do
    case Fluxer.post_to_channel(channel_id, body) do
      :ok -> :ok
      {:error, err} -> Logger.error("Fluxer command reply failed: #{inspect(err)}")
    end
  end

  defp help_embed do
    locale = locale()

    lines =
      ["nextrace", "calendar", "weather", "positions", "tyres", "teams", "drivers", "ping", "help"]
      |> Enum.map_join("\n", &"`!#{&1}`")

    %{
      type: "rich",
      color: 0xE10600,
      title: I18n.t(:help_title, locale),
      description: lines
    }
  end

  def locale, do: F1Bot.get_env(:fluxer_locale, :en)
end
