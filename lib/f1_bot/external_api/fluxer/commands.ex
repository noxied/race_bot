defmodule F1Bot.ExternalApi.Fluxer.Commands do
  @moduledoc """
  Parses `!` prefix commands from Fluxer `MESSAGE_CREATE` events and replies in the
  same channel over REST. Fluxer has no slash commands, so this is the equivalent
  of the Discord slash command layer, reusing each command's `payload/1`.
  """
  require Logger

  alias F1Bot.ExternalApi.Fluxer
  alias F1Bot.ExternalApi.Discord.I18n

  alias F1Bot.ExternalApi.Discord.Commands.{
    NextRace,
    Calendar,
    Weather,
    Positions,
    Tyres,
    Teams,
    Drivers
  }

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

  defp dispatch("nextrace", _args, ch), do: reply_payload(ch, NextRace.payload(locale()))
  defp dispatch("next-race", args, ch), do: dispatch("nextrace", args, ch)
  defp dispatch("calendar", _args, ch), do: reply_payload(ch, Calendar.payload(locale()))
  defp dispatch("weather", _args, ch), do: reply_payload(ch, Weather.payload(locale()))
  defp dispatch("positions", _args, ch), do: reply_payload(ch, Positions.payload(locale()))
  defp dispatch("tyres", _args, ch), do: reply_payload(ch, Tyres.payload(locale()))
  defp dispatch("teams", _args, ch), do: reply_payload(ch, Teams.payload(locale()))
  defp dispatch("drivers", _args, ch), do: reply_payload(ch, Drivers.payload(locale()))
  defp dispatch("highlights", args, ch), do: reply(ch, %{content: highlights_reply(args)})

  defp dispatch(_unknown, _args, _ch), do: :ok

  # ---- helpers ------------------------------------------------------------

  defp reply_payload(ch, {:embeds, embeds}), do: reply(ch, %{embeds: embeds})
  defp reply_payload(ch, {:message, content}), do: reply(ch, %{content: content})

  # ---- !highlights --------------------------------------------------------

  defp highlights_reply([]) do
    case F1Bot.Highlights.latest_overall() do
      nil -> "Ainda não há highlights no catálogo."
      v -> "🎬 **Últimos highlights · #{v.series} · #{v.gp_name} · #{v.session_type}**\n#{v.url}"
    end
  end

  defp highlights_reply(args) do
    {series, year, gp} = parse_highlights_args(args)

    cond do
      year == nil or gp == "" ->
        "Uso: `!highlights` ou `!highlights <GP> <ano> [F1|F2|F3]`"

      true ->
        case F1Bot.Highlights.find_gp(series, gp, year) do
          {:ok, _source, videos} -> format_highlights(series, gp, year, videos)
          :not_found -> "Sem highlights para **#{series} · #{gp} #{year}**."
          {:error, _} -> "Não consegui procurar agora, tenta mais tarde."
        end
    end
  end

  defp parse_highlights_args(args) do
    year =
      Enum.find_value(args, fn a ->
        case Integer.parse(a) do
          {y, ""} when y > 1900 -> y
          _ -> nil
        end
      end)

    series =
      Enum.find_value(args, fn a -> if Regex.match?(~r/^f[123]$/i, a), do: String.upcase(a) end) || "F1"

    gp =
      args
      |> Enum.reject(fn a -> a == to_string(year) or Regex.match?(~r/^f[123]$/i, a) end)
      |> Enum.join(" ")

    {series, year, gp}
  end

  defp format_highlights(series, gp, year, videos) do
    lines =
      videos
      |> Enum.sort_by(&(&1.published_at || ~U[1970-01-01 00:00:00Z]), DateTime)
      |> Enum.map_join("\n", fn v -> "• #{v.session_type}: #{v.url}" end)

    "🎬 **Highlights · #{series} · #{gp} #{year}**\n#{lines}"
  end

  defp reply(channel_id, body) do
    case Fluxer.post_to_channel(channel_id, body) do
      :ok -> :ok
      {:error, err} -> Logger.error("Fluxer command reply failed: #{inspect(err)}")
    end
  end

  defp help_embed do
    locale = locale()

    lines =
      ["nextrace", "calendar", "weather", "positions", "tyres", "teams", "drivers", "highlights", "ping", "help"]
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
