defmodule F1Bot.F1Session.LiveTimingHandlers.SessionStatus do
  @moduledoc """
  Handler for session status received from live timing API.

  The handler parses the status as an atom and passes it on to the F1 session instance.
  """
  require Logger
  alias F1Bot.F1Session.LiveTimingHandlers

  alias F1Bot.F1Session
  alias LiveTimingHandlers.{Packet, ProcessingResult}

  @behaviour LiveTimingHandlers
  @scope "SessionStatus"

  @impl F1Bot.F1Session.LiveTimingHandlers
  def process_packet(
        session,
        %Packet{
          topic: @scope,
          data: %{"Status" => status},
          init: init
        },
        _options
      ) do
    status =
      status
      |> String.trim()
      |> String.downcase()
      |> String.to_atom()

    {session, events} = F1Session.push_session_status(session, status)

    # On (re)connect the snapshot replays the current status as an init packet.
    # Don't emit notifications for it, otherwise the bot announces a session
    # "just started" (and mislabels the qualifying segment) when it merely
    # joined an in-progress session.
    events = if init, do: [], else: events

    result = %ProcessingResult{
      session: session,
      events: events
    }

    {:ok, result}
  end
end
