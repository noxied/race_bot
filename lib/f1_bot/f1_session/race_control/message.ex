defmodule F1Bot.F1Session.RaceControl.Message do
  @moduledoc ""
  use TypedStruct

  typedstruct do
    @typedoc "Race Control Message"

    field(:source, String.t())
    field(:message, String.t())
    field(:flag, atom())
    field(:mentions, list())
    # Stable per-message id from the feed (its UTC timestamp), used to dedupe
    # when backfilling missed messages after a reconnect.
    field(:dedup_key, String.t())
  end

  def new do
    %__MODULE__{}
  end
end
