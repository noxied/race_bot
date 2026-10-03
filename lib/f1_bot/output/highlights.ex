defmodule F1Bot.Output.Highlights do
  @moduledoc """
  Posts the official session highlights video once it appears on the official
  FORMULA 1 YouTube channel, and catalogues it in the `highlights` table.

  Triggers on a session ending (`finalised` or `ends`, so a restart around the
  end still fires), skips sessions already in the catalogue to avoid reposting,
  then polls the YouTube Data API (via `F1Bot.Highlights`) up to
  `:highlights_max_attempts` times and posts the link to the highlights channel.
  Only a link is posted, never a download. Inert without a `:youtube_api_key`.
  """
  use GenServer
  require Logger

  alias F1Bot.Highlights

  @end_scopes ["session_status:finalised", "session_status:ends"]
  @sessions ["Race", "Qualifying", "Sprint", "Sprint Qualifying", "Sprint Shootout"]

  def start_link(init_arg), do: GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    Enum.each(@end_scopes, &F1Bot.PubSub.subscribe_to_event/1)
    {:ok, %{pending: %{}, done: MapSet.new()}}
  end

  @impl true
  def handle_info(
        %{scope: scope, payload: %{gp_name: gp_name, session_type: session_type}},
        state
      )
      when scope in @end_scopes and is_binary(gp_name) and is_binary(session_type) do
    key = {gp_name, session_type}

    cond do
      Highlights.api_key() == nil ->
        {:noreply, state}

      session_type not in @sessions ->
        # Practice sessions do not get official highlights; skip to save quota.
        {:noreply, state}

      MapSet.member?(state.done, key) or Map.has_key?(state.pending, key) ->
        {:noreply, state}

      Highlights.catalogued?("F1", gp_name, session_type) ->
        # Already found and posted (e.g. before a restart); do not repost.
        {:noreply, %{state | done: MapSet.put(state.done, key)}}

      true ->
        Logger.info("[HIGHLIGHTS] #{gp_name} #{session_type} ended; looking for highlights")

        published_after =
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-900, :second)

        schedule_poll(key)

        search = %{
          gp_name: gp_name,
          session_type: session_type,
          published_after: published_after,
          attempts: 0
        }

        {:noreply, %{state | pending: Map.put(state.pending, key, search)}}
    end
  end

  def handle_info(%{scope: scope}, state) when scope in @end_scopes, do: {:noreply, state}

  def handle_info({:poll, key}, state) do
    case Map.get(state.pending, key) do
      nil ->
        {:noreply, state}

      search ->
        attempts = search.attempts + 1

        case Highlights.find_for_session("F1", search.gp_name, search.session_type, search.published_after) do
          {:ok, attrs} ->
            Highlights.upsert(attrs)
            Logger.info("[HIGHLIGHTS] found: #{attrs.title} -> #{attrs.url}")
            post(search.gp_name, search.session_type, attrs.url)
            {:noreply, drop(state, key, :done)}

          other ->
            if match?({:error, _}, other) do
              Logger.warning("[HIGHLIGHTS] search failed (#{inspect(elem(other, 1))})")
            end

            if attempts >= Highlights.max_attempts() do
              Logger.info("[HIGHLIGHTS] giving up on #{elem(key, 0)} #{elem(key, 1)}")
              {:noreply, drop(state, key, :pending)}
            else
              schedule_poll(key)
              {:noreply, %{state | pending: Map.put(state.pending, key, %{search | attempts: attempts})}}
            end
        end
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp drop(state, key, :done),
    do: %{state | pending: Map.delete(state.pending, key), done: MapSet.put(state.done, key)}

  defp drop(state, key, :pending), do: %{state | pending: Map.delete(state.pending, key)}

  defp schedule_poll(key) do
    Process.send_after(self(), {:poll, key}, Highlights.poll_minutes() * 60_000)
  end

  defp post(gp_name, session_type, url) do
    message = "🎬 **Highlights oficiais · #{gp_name} · #{session_type}**\n#{url}"
    F1Bot.ExternalApi.Discord.post_message({:highlights, message})
  end
end
