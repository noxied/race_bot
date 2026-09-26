defmodule F1Bot.F1Session.LiveTimingHandlers.TeamRadio do
  @moduledoc """
  Handler for the `TeamRadio` topic. Emits a `team_radio:clip` event per new radio
  capture (driver number + audio url), which `F1Bot.Output.TeamRadio` turns into a
  posted audio clip.

  Only live deltas are handled: the router lets the reconnect snapshot fall to the
  generic init clause, so clips are never re-posted after a reconnect.
  """
  alias F1Bot.F1Session.Common.Event
  alias F1Bot.F1Session.LiveTimingHandlers.{Packet, ProcessingResult}

  @behaviour F1Bot.F1Session.LiveTimingHandlers
  @scope "TeamRadio"

  @impl F1Bot.F1Session.LiveTimingHandlers
  def process_packet(session, %Packet{topic: @scope, data: data}, _options) do
    www = session.session_info.www_path

    clips =
      data
      |> extract_captures()
      |> Enum.map(fn c -> {c, audio_url(www, c.path)} end)
      |> Enum.reject(fn {_c, url} -> url == nil end)

    numbers =
      clips |> Enum.map(fn {c, _url} -> c.driver_number end) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    events =
      clips
      |> Enum.map(fn {c, url} ->
        Event.new("team_radio:clip", %{
          driver_number: c.driver_number,
          audio_url: url,
          path: c.path,
          utc: c.utc
        })
      end)
      |> Event.attach_session_info(session)
      |> Event.attach_driver_info(session, numbers)

    {:ok, %ProcessingResult{session: session, events: events}}
  end

  @impl F1Bot.F1Session.LiveTimingHandlers
  def process_packet(_session, _invalid_packet, _options), do: {:error, :invalid_packet}

  defp extract_captures(%{"Captures" => list}) when is_list(list), do: Enum.map(list, &capture/1)

  defp extract_captures(%{"Captures" => map}) when is_map(map),
    do: map |> Map.values() |> Enum.map(&capture/1)

  defp extract_captures(_), do: []

  defp capture(c) do
    %{driver_number: parse_int(c["RacingNumber"]), path: c["Path"], utc: c["Utc"]}
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp audio_url(www, path) when is_binary(www) and is_binary(path) do
    base = www |> String.trim_trailing("/") |> String.replace_prefix("http://", "https://")
    "#{base}/#{String.trim_leading(path, "/")}"
  end

  defp audio_url(_www, _path), do: nil
end
