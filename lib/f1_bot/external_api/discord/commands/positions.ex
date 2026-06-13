defmodule F1Bot.ExternalApi.Discord.Commands.Positions do
  @moduledoc """
  Slash command `/positions` - the live running order of the current session
  from the F1 live timing feed, rendered as three columns: position/driver,
  best lap (or gap to leader during a race), and tyre history with current age.
  Available while a session is live.
  """
  alias Nostrum.Struct.Interaction
  alias F1Bot.DataTransform.Format
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
    %{
      type: "rich",
      color: @color,
      title: title(data, locale),
      fields: fields(data, locale),
      footer: %{text: footer_text(data, locale)}
    }
  end

  # ---- columns -----------------------------------------------------------

  defp fields(data, locale) do
    s = data.standings

    [
      %{name: I18n.t(:positions_col_driver, locale), value: col_driver(s), inline: true},
      second_field(data, locale),
      %{name: I18n.t(:positions_col_tyres, locale), value: col_tyres(s), inline: true}
    ]
  end

  defp second_field(%{race: true} = data, locale),
    do: %{name: I18n.t(:positions_col_gap, locale), value: col_gap(data.standings), inline: true}

  defp second_field(data, locale),
    do: %{name: I18n.t(:positions_col_bestlap, locale), value: col_bestlap(data.standings), inline: true}

  defp col_driver(standings) do
    Enum.map_join(standings, "\n", fn e ->
      pos = e.position |> to_string() |> String.pad_leading(2)
      "`P#{pos}` `#{e.abbr}`#{driver_marker(e)}"
    end)
  end

  defp driver_marker(%{retired: true}), do: " **OUT**"
  defp driver_marker(%{in_pit: true}), do: " 🅿️"
  defp driver_marker(_), do: ""

  defp col_bestlap(standings) do
    Enum.map_join(standings, "\n", fn e ->
      fl = if e.fastest_lap and e.best_lap_ms, do: " #{fastest_emoji()}", else: ""
      "`#{format_ms(e.best_lap_ms)}`#{fl}"
    end)
  end

  defp col_gap(standings) do
    Enum.map_join(standings, "\n", fn e -> "`#{gap_value(e)}`" end)
  end

  defp gap_value(e) do
    cond do
      e.position == 1 -> "-"
      e.interval -> e.interval
      e.gap_to_leader -> e.gap_to_leader
      true -> "-"
    end
  end

  # Past stints as compact letters, current stint as the custom emoji + age.
  # Custom emoji codes are ~27 chars each, so only the current tyre uses one to
  # stay within Discord's 1024-char field limit across the full grid.
  defp col_tyres(standings) do
    Enum.map_join(standings, "\n", &tyre_cell/1)
  end

  defp tyre_cell(%{tyres: []}), do: "`-`"

  defp tyre_cell(e) do
    {past, [current]} = Enum.split(e.tyres, length(e.tyres) - 1)

    prefix =
      case Enum.map_join(past, " ", &tyre_letter/1) do
        "" -> ""
        letters -> "`#{letters}` "
      end

    "#{prefix}#{tyre_emoji(current)}#{tyre_age(e.tyre_age)}"
  end

  defp tyre_age(age) when is_integer(age), do: " `#{age}`"
  defp tyre_age(_), do: ""

  defp tyre_letter(:soft), do: "S"
  defp tyre_letter(:medium), do: "M"
  defp tyre_letter(:hard), do: "H"
  defp tyre_letter(:intermediate), do: "I"
  defp tyre_letter(:wet), do: "W"
  defp tyre_letter(_), do: "?"

  # ---- helpers -----------------------------------------------------------

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

  defp footer_text(%{live: true}, locale), do: I18n.t(:positions_footer_live, locale)
  defp footer_text(_data, locale), do: I18n.t(:positions_footer_stale, locale)

  defp format_ms(nil), do: "-"

  defp format_ms(ms) when is_integer(ms),
    do: Format.format_lap_time(Timex.Duration.from_milliseconds(ms))

  defp fastest_emoji,
    do: F1Bot.ExternalApi.Discord.get_emoji_or_default(:fastest_lap, "🟣")

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
