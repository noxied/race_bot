defmodule F1Bot.ExternalApi.Discord.Commands.Positions do
  @moduledoc """
  Slash command `/positions` - the live running order of the current session
  from the F1 live timing feed, rendered as two columns: position/driver and
  best lap (or gap to leader during a race). Tyre history lives in `/tyres`.
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
      %{name: I18n.t(:positions_col_driver, locale), value: col_driver(s, data.live), inline: true},
      second_field(data, locale)
    ]
  end

  defp second_field(%{race: true} = data, locale),
    do: %{name: I18n.t(:positions_col_gap, locale), value: col_gap(data.standings), inline: true}

  defp second_field(data, locale),
    do: %{name: I18n.t(:positions_col_bestlap, locale), value: col_bestlap(data.standings), inline: true}

  defp col_driver(standings, live) do
    Enum.map_join(standings, "\n", fn e ->
      pos = e.position |> to_string() |> String.pad_leading(2)
      "`P#{pos}` `#{e.name}`#{markers(e, live)}"
    end)
  end

  # Fastest-lap marker (always, both quali and race) plus retirement/pit status.
  # The pit marker is only meaningful while the session is live (otherwise every
  # car reads as parked).
  defp markers(e, live) do
    fl = if e.fastest_lap, do: " #{fastest_emoji()}", else: ""

    status =
      cond do
        e.retired -> " **OUT**"
        live and e.in_pit -> " 🅿️"
        true -> ""
      end

    fl <> status
  end

  defp col_bestlap(standings) do
    Enum.map_join(standings, "\n", fn e -> "`#{format_ms(e.best_lap_ms)}`" end)
  end

  defp col_gap(standings) do
    Enum.map_join(standings, "\n", fn e -> "`#{gap_value(e)}`" end)
  end

  # Header reads "Gap", so show gap to the leader; fall back to interval.
  defp gap_value(e) do
    cond do
      e.position == 1 -> "-"
      e.gap_to_leader -> e.gap_to_leader
      e.interval -> e.interval
      true -> "-"
    end
  end

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
end
