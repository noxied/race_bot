defmodule F1Bot.ExternalApi.Discord.Commands.Weather do
  @moduledoc """
  Slash command `/weather` - track weather from the F1 live timing feed
  (air/track temperature, humidity, pressure, rainfall, wind). Available while
  the session feed is live; otherwise shows the last readings of the session.
  """
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common}

  @color 0x3498DB

  def handle_interaction(interaction = %Interaction{}) do
    flags = Common.response_flags(interaction)
    locale = Common.locale(interaction)

    response =
      case F1Bot.weather() do
        {:ok, weather} when map_size(weather) > 0 ->
          Response.make_embed_message(flags, [build_embed(weather, locale, live?())])

        _ ->
          Response.make_message(flags, I18n.t(:weather_none, locale))
      end

    Response.send_interaction_response(response, interaction)
  end

  defp live?, do: match?({:ok, :started}, F1Bot.session_status())

  defp build_embed(w, locale, live) do
    footer = if live, do: :weather_footer, else: :weather_footer_stale

    %{
      type: "rich",
      color: @color,
      title: "⛅ #{I18n.t(:weather_title, locale)}",
      fields: [
        field(I18n.t(:weather_air, locale), temp(w[:air_temp])),
        field(I18n.t(:weather_track, locale), temp(w[:track_temp])),
        field(I18n.t(:weather_wind, locale), wind(w)),
        field(I18n.t(:weather_humidity, locale), percent(w[:humidity])),
        field(I18n.t(:weather_pressure, locale), pressure(w[:pressure])),
        field(I18n.t(:weather_rain, locale), rain(w[:rainfall], locale))
      ],
      footer: %{text: I18n.t(footer, locale)}
    }
  end

  defp field(name, value), do: %{name: name, value: value, inline: true}

  defp temp(t) when is_number(t), do: "#{t}°C"
  defp temp(_), do: "-"

  defp percent(h) when is_number(h), do: "#{h}%"
  defp percent(_), do: "-"

  defp pressure(p) when is_number(p), do: "#{p} hPa"
  defp pressure(_), do: "-"

  # F1 reports wind speed in m/s; show km/h with the direction in degrees.
  defp wind(%{wind_speed: s} = w) when is_number(s) do
    kmh = Float.round(s * 3.6, 1)

    case w[:wind_direction] do
      d when is_number(d) -> "#{kmh} km/h (#{trunc(d)}°)"
      _ -> "#{kmh} km/h"
    end
  end

  defp wind(_), do: "-"

  defp rain(r, locale) when is_number(r) and r >= 1, do: I18n.t(:weather_rain_yes, locale)
  defp rain(_r, locale), do: I18n.t(:weather_rain_no, locale)
end
