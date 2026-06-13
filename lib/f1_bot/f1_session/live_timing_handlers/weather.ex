defmodule F1Bot.F1Session.LiveTimingHandlers.Weather do
  @moduledoc """
  Handler for the WeatherData topic from the live timing API. Stores the latest
  readings (air/track temperature, humidity, pressure, rainfall, wind) in the
  session so they can be served by the /weather command.
  """
  alias F1Bot.F1Session
  alias F1Bot.F1Session.LiveTimingHandlers
  alias LiveTimingHandlers.{Packet, ProcessingResult}

  @behaviour LiveTimingHandlers
  @scope "WeatherData"

  @impl LiveTimingHandlers
  def process_packet(session, %Packet{topic: @scope, data: data}, _options) do
    session = F1Session.push_weather(session, parse(data))

    {:ok, %ProcessingResult{session: session, events: []}}
  end

  defp parse(data) do
    %{
      air_temp: num(data["AirTemp"]),
      track_temp: num(data["TrackTemp"]),
      humidity: num(data["Humidity"]),
      pressure: num(data["Pressure"]),
      rainfall: num(data["Rainfall"]),
      wind_speed: num(data["WindSpeed"]),
      wind_direction: num(data["WindDirection"])
    }
  end

  defp num(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp num(value) when is_number(value), do: value
  defp num(_), do: nil
end
