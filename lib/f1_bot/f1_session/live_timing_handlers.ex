defmodule F1Bot.F1Session.LiveTimingHandlers do
  @moduledoc """
  Router for all packets ingested from F1 SignalR websocket API
  """
  require Logger
  alias F1Bot.F1Session
  alias F1Bot.F1Session.LiveTimingHandlers
  alias F1Bot.F1Session.LiveTimingHandlers.{Packet, ProcessingResult, ProcessingOptions}

  @callback process_packet(F1Session.t(), Packet.t(), ProcessingOptions.t()) ::
              {:ok, ProcessingResult.t()} | {:error, any()}

  @session_inactive_statuses [nil, :finalised, :ends]

  @doc """
  Ingestion point for processing received packets. Called by `F1Bot.F1Session.Server` for packets
  received from SignalR and by `F1Bot.Replay` when processing session replays.
  """
  def process_live_timing_packet(
        session = %F1Session{},
        packet = %Packet{},
        options = %ProcessingOptions{}
      ) do
    if not is_function(options.local_time_fn, 0) do
      raise ArgumentError, "local_time_fn/0 must be provided in Processing options"
    end

    process_for_topic(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "DriverList"}, options) do
    LiveTimingHandlers.DriverList.process_packet(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "SessionInfo"}, options) do
    LiveTimingHandlers.SessionInfo.process_packet(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "SessionStatus"}, options) do
    LiveTimingHandlers.SessionStatus.process_packet(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "ExtrapolatedClock"}, options) do
    LiveTimingHandlers.ExtrapolatedClock.process_packet(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "LapCount"}, options) do
    LiveTimingHandlers.LapCount.process_packet(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "WeatherData"}, options) do
    LiveTimingHandlers.Weather.process_packet(session, packet, options)
  end

  # Reconnect snapshot for race control: the feed replays the whole session's
  # messages as an init packet. Backfill what was missed during downtime only
  # when the session is actually live (so a restart after a session is over does
  # not dump old messages into the channel) and we already have history to dedupe
  # against (so a cold start does not re-post the entire session).
  defp process_for_topic(
         session,
         packet = %Packet{topic: "RaceControlMessages", init: true},
         options
       ) do
    if session.race_control.messages != [] and session.session_status in [:started, :aborted] do
      LiveTimingHandlers.RaceControlMessages.process_packet(session, packet, options)
    else
      {:ok, %ProcessingResult{session: session, events: []}}
    end
  end

  # Ignore initialization messages sent on other topics
  defp process_for_topic(session, _packet = %Packet{init: true}, _options) do
    result = %ProcessingResult{
      session: session,
      events: []
    }

    {:ok, result}
  end

  # TODO: Implement time-synchronization
  defp process_for_topic(session, _packet = %Packet{topic: "Heartbeat"}, _options) do
    result = %ProcessingResult{
      session: session,
      events: []
    }

    {:ok, result}
  end

  # Allow post-session Race Control messages (e.g. late penalties, investigations)
  # to keep flowing after a session ends/finalises. The live timing feed goes quiet
  # on its own once F1 stops broadcasting, so this self-bounds without an arbitrary
  # timer. `nil` (no session at all) is still ignored to avoid stray messages.
  defp process_for_topic(session, packet = %Packet{topic: "RaceControlMessages"}, options)
       when session.session_status in [:finalised, :ends] do
    LiveTimingHandlers.RaceControlMessages.process_packet(session, packet, options)
  end

  # Ignore all other packets when session is inactive
  defp process_for_topic(session, packet = %Packet{}, options = %ProcessingOptions{})
       when session.session_status in @session_inactive_statuses do
    if options.log_stray_packets do
      Logger.info(
        "Ignored received packet on #{packet.topic} while session is inactive (#{inspect(session.session_status)})"
      )
    end

    result = %ProcessingResult{
      session: session,
      events: []
    }

    {:ok, result}
  end

  defp process_for_topic(session, packet = %Packet{topic: "CarData"}, options) do
    LiveTimingHandlers.CarTelemetry.process_packet(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "Position"}, options) do
    LiveTimingHandlers.PositionData.process_packet(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "TimingData"}, options) do
    LiveTimingHandlers.TimingData.process_packet(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "RaceControlMessages"}, options) do
    LiveTimingHandlers.RaceControlMessages.process_packet(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "TimingAppData"}, options) do
    LiveTimingHandlers.StintData.process_packet(session, packet, options)
  end

  defp process_for_topic(session, packet = %Packet{topic: "TrackStatus"}, options) do
    LiveTimingHandlers.TrackStatus.process_packet(session, packet, options)
  end

  defp process_for_topic(session, _packet = %Packet{topic: _topic}, _options) do
    # Logger.warning("Received a message for unknown topic: #{topic}")
    result = %ProcessingResult{
      session: session,
      events: []
    }

    {:ok, result}
  end
end
