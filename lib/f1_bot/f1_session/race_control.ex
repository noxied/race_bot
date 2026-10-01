defmodule F1Bot.F1Session.RaceControl do
  @moduledoc """
  Stores and generates events for messages from race control.
  """
  use TypedStruct
  alias F1Bot.F1Session

  # A reconnect during a short outage misses only a handful of messages. Anything
  # larger is a stale/cold reconnect (e.g. the feed re-serving a whole past
  # session), so it is absorbed silently instead of dumped into the channel.
  @max_backfill 8

  typedstruct do
    @typedoc "Race Control messages"

    field(:messages, [F1Session.RaceControl.Message.t()], default: [])
  end

  def new do
    %__MODULE__{}
  end

  def push_messages(
        race_control = %__MODULE__{},
        new_messages
      ) do
    messages = race_control.messages ++ new_messages
    race_control = %{race_control | messages: messages}

    events =
      for m <- new_messages do
        make_race_control_message_event(m)
      end

    {race_control, events}
  end

  @doc """
  Like `push_messages/2`, but for the reconnect snapshot: keeps only the messages
  not already stored, so a reconnect backfills what was missed during downtime
  without re-posting the whole session. Dedupes by the feed's per-message id
  (`dedup_key`); when older stored messages predate that id, falls back to
  content-based deduping for that one transition.
  """
  def backfill_messages(
        race_control = %__MODULE__{messages: existing},
        incoming
      ) do
    # `Map.get/2` (not `.dedup_key`) so this is safe against messages restored
    # from a snapshot written before the field existed (they return nil and take
    # the content-based path for that one transition).
    fresh =
      if existing != [] and Enum.all?(existing, &(Map.get(&1, :dedup_key) != nil)) do
        keys = MapSet.new(existing, &Map.get(&1, :dedup_key))
        Enum.reject(incoming, fn m -> m.dedup_key != nil and MapSet.member?(keys, m.dedup_key) end)
      else
        content = MapSet.new(existing, &content_key/1)
        Enum.reject(incoming, fn m -> MapSet.member?(content, content_key(m)) end)
      end

    cond do
      fresh == [] ->
        {race_control, []}

      length(fresh) > @max_backfill ->
        # Too many missed messages to be a real in-session gap. Absorb them into
        # history (so they are not re-posted on the next reconnect) but emit none.
        {%{race_control | messages: race_control.messages ++ fresh}, []}

      true ->
        push_messages(race_control, fresh)
    end
  end

  defp content_key(m), do: {m.flag, m.message, m.source}

  defp make_race_control_message_event(payload) do
    F1Bot.F1Session.Common.Event.new("race_control:message", payload)
  end
end
