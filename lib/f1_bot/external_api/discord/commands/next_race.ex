defmodule F1Bot.ExternalApi.Discord.Commands.NextRace do
  @moduledoc """
  Slash command `/nextrace` — shows the next F1 race weekend.

  Race metadata (circuit, country, round, layout image) comes from F1DB; exact
  session start times are overlaid from the ICS calendar (`F1Calendar`) when
  available, since F1DB lacks session times for upcoming seasons.
  """
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.{F1DB, F1Calendar}
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common}

  # F1 red
  @color 0xE10600

  # f1db hosts circuit layouts as SVG. Discord can't render SVG, so we proxy
  # through wsrv.nl which rasterises to PNG on the fly.
  @circuit_svg_base "raw.githubusercontent.com/f1db/f1db/main/src/assets/circuits/white-outline"

  @session_order [
    :free_practice_1,
    :free_practice_2,
    :free_practice_3,
    :sprint_qualifying,
    :sprint,
    :qualifying,
    :race
  ]

  # F1DB session key -> ICS calendar kind.
  @ics_kind %{
    free_practice_1: :fp1,
    free_practice_2: :fp2,
    free_practice_3: :fp3,
    sprint_qualifying: :sprint_qualifying,
    sprint: :sprint,
    qualifying: :qualifying,
    race: :race
  }

  def handle_interaction(interaction = %Interaction{}) do
    flags = Common.response_flags(interaction)
    locale = Common.locale(interaction)

    response =
      case F1DB.next_race() do
        {:ok, race} ->
          Response.make_embed_message(flags, [build_embed(race, locale)])

        {:error, :no_upcoming_race} ->
          Response.make_message(flags, I18n.t(:nextrace_none, locale))

        {:error, :not_loaded} ->
          Response.make_message(flags, I18n.t(:data_not_ready, locale))
      end

    Response.send_interaction_response(response, interaction)
  end

  defp build_embed(race, locale) do
    flag = Common.flag_emoji(race.country_code)
    now = DateTime.utc_now()
    ics = ics_weekend(race.date)

    countdown =
      case Map.get(ics, :race) do
        %DateTime{} = dt -> Common.relative_timestamp_dt(dt)
        _ -> Common.relative_timestamp(race.date, race.time)
      end

    description =
      [
        "*#{race.official_name}*",
        "",
        location_line(race),
        "🏆 #{I18n.t(:field_round, locale)} #{race.round}  ·  ⏱️ #{countdown}",
        "",
        "**#{I18n.t(:field_sessions, locale)}:**",
        format_sessions(race.sessions, ics, locale, now)
      ]
      |> Enum.reject(&(&1 == nil))
      |> Enum.join("\n")

    %{
      type: "rich",
      color: @color,
      title: String.trim("#{flag} #{I18n.t(:nextrace_title, locale)} — #{race.grand_prix}"),
      description: description,
      footer: %{text: I18n.t(:tz_footer, locale)}
    }
    |> maybe_put_image(circuit_image_url(race.circuit_layout_id))
  end

  defp ics_weekend(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> F1Calendar.weekend_sessions(date)
      _ -> %{}
    end
  end

  defp location_line(%{place_name: place, country: country})
       when is_binary(place) and is_binary(country),
       do: "🌍 #{place}, #{country}"

  defp location_line(%{country: country}) when is_binary(country), do: "🌍 #{country}"
  defp location_line(_), do: nil

  defp format_sessions(sessions, ics, locale, now) do
    @session_order
    |> Enum.filter(&Map.has_key?(sessions, &1))
    |> Enum.map_join("\n", fn key ->
      icon = if key == :race, do: "🏎️", else: "🗓️"

      {timestamp, past?} =
        case Map.get(ics, Map.get(@ics_kind, key)) do
          %DateTime{} = dt ->
            {Common.session_timestamp_dt(dt), Common.past_dt?(dt, now)}

          _ ->
            %{date: date, time: time} = sessions[key]
            {Common.session_timestamp(date, time), Common.session_past?(date, time, now)}
        end

      line = "#{icon} **#{I18n.session_label(key, locale)}** — #{timestamp}"
      if past?, do: "~~#{line}~~", else: line
    end)
  end

  defp circuit_image_url(nil), do: nil

  defp circuit_image_url(layout_id),
    do: "https://wsrv.nl/?url=#{@circuit_svg_base}/#{layout_id}.svg&output=png&w=450"

  defp maybe_put_image(embed, nil), do: embed
  defp maybe_put_image(embed, url), do: Map.put(embed, :image, %{url: url})
end
