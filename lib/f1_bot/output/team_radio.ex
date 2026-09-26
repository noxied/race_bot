defmodule F1Bot.Output.TeamRadio do
  @moduledoc """
  Downloads team radio clips as they arrive on the live feed and posts them (audio
  attached) to the Fluxer radio channels. Clips are processed one at a time, at
  most one every couple of seconds, and deduped by audio path. Enabled by the
  `:fluxer_radio_clips` flag; when the upload fails it falls back to posting the
  clip URL.
  """
  use GenServer
  require Logger

  alias F1Bot.PubSub
  alias F1Bot.F1Session.Common.Event
  alias F1Bot.Output.Common
  alias F1Bot.ExternalApi.Fluxer

  @finch F1Bot.Finch
  @scope "team_radio:clip"
  @pace_ms 2_000
  @download_attempts 3
  @retry_ms 2_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    PubSub.subscribe_to_event(@scope)
    {:ok, %{seen: MapSet.new(), queue: :queue.new(), busy: false}}
  end

  @impl true
  def handle_info(%Event{scope: @scope, payload: %{path: path}} = event, state) do
    state =
      if MapSet.member?(state.seen, path) do
        state
      else
        %{state | seen: MapSet.put(state.seen, path), queue: :queue.in(event, state.queue)}
        |> maybe_start()
      end

    {:noreply, state}
  end

  def handle_info(:clip_done, state) do
    Process.send_after(self(), :next, @pace_ms)
    {:noreply, state}
  end

  def handle_info(:next, state) do
    {:noreply, maybe_start(%{state | busy: false})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Start processing the next queued clip unless one is already in flight.
  defp maybe_start(%{busy: true} = state), do: state

  defp maybe_start(%{busy: false} = state) do
    case :queue.out(state.queue) do
      {{:value, event}, queue} ->
        parent = self()

        Task.start(fn ->
          process_clip(event)
          send(parent, :clip_done)
        end)

        %{state | queue: queue, busy: true}

      {:empty, _} ->
        state
    end
  end

  defp process_clip(%Event{payload: payload} = event) do
    num = payload.driver_number
    caption = caption(event, num)
    filename = payload.path |> to_string() |> Path.basename()
    channels = F1Bot.get_env(:fluxer_channel_ids_radios, [])

    Logger.info("[TEAM RADIO] #{caption} (#{filename}) -> channels #{inspect(channels)}")

    case download(payload.audio_url) do
      {:ok, binary} ->
        for ch <- channels do
          case Fluxer.post_audio_clip(ch, caption, filename, binary) do
            :ok ->
              :ok

            {:error, err} ->
              Logger.warning("Team radio upload failed (#{inspect(err)}), posting link instead")
              Fluxer.post_to_channel(ch, %{content: "#{caption}\n#{payload.audio_url}"})
          end
        end

      {:error, err} ->
        Logger.warning("Team radio download failed (#{inspect(err)}): #{payload.audio_url}")
    end
  end

  # "📻 **VER** · Max Verstappen (Red Bull Racing) · Lap 23"
  defp caption(event, num) do
    abbr = Common.get_driver_abbr_by_number(event, num)
    info = get_in(event.meta, [:driver_info, num])
    name = info && (info.full_name || info.last_name)
    team = info && info.team_name
    lap = event.meta[:lap_number]

    [
      "📻 **#{abbr}**",
      name && "· #{name}",
      team && "(#{team})",
      lap && "· Lap #{lap}"
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join(" ")
  end

  defp download(url, attempts \\ @download_attempts)

  defp download(_url, 0), do: {:error, :exhausted}

  defp download(url, attempts) do
    case Finch.build(:get, url) |> Finch.request(@finch, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      _other ->
        Process.sleep(@retry_ms)
        download(url, attempts - 1)
    end
  end
end
