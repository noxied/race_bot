defmodule F1Bot.ExternalApi.Discord.Commands.Positions do
  @moduledoc """
  Slash command `/positions` - the live running order of the current session
  (position, driver, tyre, interval / gap to leader) from the F1 live timing
  feed. Available while a session is live.
  """
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common}

  # F1 red
  @color 0xE10600

  def handle_interaction(interaction = %Interaction{}) do
    flags = Common.response_flags(interaction)
    locale = Common.locale(interaction)

    response =
      case F1Bot.live_standings() do
        {:ok, %{standings: [_ | _]} = data} ->
          Response.make_embed_message(flags, [build_embed(data, locale)])

        _ ->
          Response.make_message(flags, I18n.t(:positions_none, locale))
      end

    Response.send_interaction_response(response, interaction)
  end

  defp build_embed(data, locale) do
    lines = Enum.map_join(data.standings, "\n", &line/1)

    %{
      type: "rich",
      color: @color,
      title: title(data, locale),
      description: lines,
      footer: %{text: footer_text(data, locale)}
    }
  end

  defp footer_text(%{live: true}, locale), do: I18n.t(:positions_footer_live, locale)
  defp footer_text(_data, locale), do: I18n.t(:positions_footer_stale, locale)

  defp title(data, locale) do
    base = "🏁 #{I18n.t(:positions_title, locale)}"

    parts =
      [data.gp_name, data.session_type, lap_text(data)]
      |> Enum.reject(&(&1 == nil))

    case parts do
      [] -> base
      _ -> base <> " - " <> Enum.join(parts, " · ")
    end
  end

  defp lap_text(%{lap_current: c, lap_total: t}) when is_integer(c) and is_integer(t),
    do: "Lap #{c}/#{t}"

  defp lap_text(_), do: nil

  defp line(e) do
    pos = e.position |> to_string() |> String.pad_leading(2)
    fl = if e.fastest_lap, do: " #{fastest_emoji()}", else: ""
    "`P#{pos}` #{tyre(e)} `#{e.abbr}` #{gap_text(e)}#{fl}"
  end

  defp tyre(e) do
    emoji = tyre_emoji(e.tyre)

    case e.tyre_age do
      age when is_integer(age) -> "#{emoji} `#{age |> to_string() |> String.pad_leading(2)}`"
      _ -> emoji
    end
  end

  defp fastest_emoji,
    do: F1Bot.ExternalApi.Discord.get_emoji_or_default(:fastest_lap, "🟣")

  defp gap_text(%{retired: true}), do: "**OUT**"

  defp gap_text(e) do
    pit = if e.in_pit, do: "🅿️ ", else: ""

    gap =
      cond do
        e.position == 1 -> ""
        e.interval && e.gap_to_leader -> "#{e.interval}  (#{e.gap_to_leader})"
        e.interval -> e.interval
        e.gap_to_leader -> e.gap_to_leader
        true -> ""
      end

    "#{pit}#{gap}"
  end

  defp tyre_emoji(nil), do: "⬤"

  defp tyre_emoji(compound) do
    default =
      case compound do
        :soft -> "🔴"
        :medium -> "🟡"
        :hard -> "⚪"
        :intermediate -> "🟢"
        :wet -> "🔵"
        _ -> "⬤"
      end

    F1Bot.ExternalApi.Discord.get_emoji_or_default(:"#{compound}_tyre", default)
  end
end
