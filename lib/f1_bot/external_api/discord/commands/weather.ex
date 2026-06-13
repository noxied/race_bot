defmodule F1Bot.ExternalApi.Discord.Commands.Weather do
  @moduledoc """
  Slash command `/weather` - live track weather from the OpenF1 API
  (available during an active session; updates roughly every minute).
  """
  require Logger
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common}

  @finch F1Bot.Finch
  @url "https://api.openf1.org/v1/weather?meeting_key=latest&session_key=latest"
  @color 0x3498DB

  def handle_interaction(interaction = %Interaction{}) do
    flags = Common.response_flags(interaction)
    locale = Common.locale(interaction)

    # OpenF1 is an HTTP call, so acknowledge first and follow up with the result.
    flags
    |> Response.make_deferred_message()
    |> Response.send_interaction_response(interaction)

    case fetch_latest() do
      {:ok, weather} ->
        flags
        |> Response.make_followup_message(nil, [], [build_embed(weather, locale)])
        |> Response.send_followup_response(interaction)

      {:error, :no_data} ->
        flags
        |> Response.make_followup_message(I18n.t(:weather_none, locale))
        |> Response.send_followup_response(interaction)

      {:error, _reason} ->
        flags
        |> Response.make_followup_message(I18n.t(:data_not_ready, locale))
        |> Response.send_followup_response(interaction)
    end
  end

  defp fetch_latest do
    case Finch.build(:get, @url, [{"user-agent", "f1bot"}])
         |> Finch.request(@finch, receive_timeout: 8_000) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, [_ | _] = list} -> {:ok, List.last(list)}
          {:ok, _} -> {:error, :no_data}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_embed(w, locale) do
    %{
      type: "rich",
      color: @color,
      title: "⛅ #{I18n.t(:weather_title, locale)}",
      fields: [
        field(I18n.t(:weather_air, locale), "#{num(w["air_temperature"])}°C"),
        field(I18n.t(:weather_track, locale), "#{num(w["track_temperature"])}°C"),
        field(I18n.t(:weather_wind, locale), wind(w)),
        field(I18n.t(:weather_humidity, locale), "#{num(w["humidity"])}%"),
        field(I18n.t(:weather_pressure, locale), "#{num(w["pressure"])} hPa"),
        field(I18n.t(:weather_rain, locale), rain(w["rainfall"], locale))
      ],
      footer: %{text: I18n.t(:weather_footer, locale)}
    }
  end

  defp field(name, value), do: %{name: name, value: value, inline: true}

  defp num(nil), do: "-"
  defp num(v), do: to_string(v)

  # OpenF1 wind_speed is m/s; show km/h with the cardinal direction in degrees.
  defp wind(%{"wind_speed" => speed} = w) when is_number(speed) do
    kmh = Float.round(speed * 3.6, 1)

    case w["wind_direction"] do
      dir when is_number(dir) -> "#{kmh} km/h (#{dir}°)"
      _ -> "#{kmh} km/h"
    end
  end

  defp wind(_), do: "-"

  defp rain(value, locale) when value in [1, true], do: I18n.t(:weather_rain_yes, locale)
  defp rain(_value, locale), do: I18n.t(:weather_rain_no, locale)
end
