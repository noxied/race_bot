defmodule F1Bot.Output.Highlights do
  @moduledoc """
  Posts the official session highlights video once it appears on the official
  FORMULA 1 YouTube channel.

  When a session is finalised it starts polling the YouTube Data API (restricted
  to the official channel, `publishedAfter` the session end, plus a title filter)
  every `:highlights_poll_minutes`, up to `:highlights_max_attempts` times, and
  posts the link to the first matching video. Only a link is posted, never a
  download. Inert without a `:youtube_api_key`.
  """
  use GenServer
  require Logger

  @search_url "https://www.googleapis.com/youtube/v3/search"
  # Official FORMULA 1 channel; overridable with YOUTUBE_CHANNEL_ID.
  @default_channel_id "UCB_qr75-ydFVKSF9Dmo6izg"
  @finch F1Bot.Finch

  def start_link(init_arg), do: GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    F1Bot.PubSub.subscribe_to_event("session_status:finalised")
    {:ok, %{pending: %{}, done: MapSet.new()}}
  end

  @impl true
  def handle_info(
        %{
          scope: "session_status:finalised",
          payload: %{gp_name: gp_name, session_type: session_type}
        },
        state
      )
      when is_binary(gp_name) and is_binary(session_type) do
    key = {gp_name, session_type}

    cond do
      api_key() == nil ->
        {:noreply, state}

      not highlights_session?(session_type) ->
        # Practice sessions do not get official highlights, so skip them rather
        # than poll (and burn API quota) for a video that never appears.
        {:noreply, state}

      MapSet.member?(state.done, key) or Map.has_key?(state.pending, key) ->
        {:noreply, state}

      true ->
        Logger.info("[HIGHLIGHTS] #{gp_name} #{session_type} finalised; looking for highlights")
        # Highlights are published after the session, so bound the search to just
        # before it ended. A small margin covers clock skew without reaching back
        # to a previous session's upload.
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

  def handle_info(%{scope: "session_status:finalised"}, state), do: {:noreply, state}

  def handle_info({:poll, key}, state) do
    case Map.get(state.pending, key) do
      nil ->
        {:noreply, state}

      search ->
        attempts = search.attempts + 1

        case find_video(search) do
          {:ok, url, title} ->
            Logger.info("[HIGHLIGHTS] found: #{title} -> #{url}")
            post(search.gp_name, search.session_type, url)
            {:noreply, drop(state, key, :done)}

          other ->
            if match?({:error, _}, other) do
              Logger.warning("[HIGHLIGHTS] search failed (#{inspect(elem(other, 1))})")
            end

            if attempts >= max_attempts() do
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

  # ---- polling ------------------------------------------------------------

  defp schedule_poll(key) do
    Process.send_after(self(), {:poll, key}, poll_minutes() * 60_000)
  end

  defp find_video(%{gp_name: gp_name, session_type: session_type, published_after: published_after}) do
    query =
      URI.encode_query(%{
        "part" => "snippet",
        "channelId" => channel_id(),
        "q" => "#{gp_name} #{simple_label(session_type)} highlights",
        "type" => "video",
        "order" => "date",
        "maxResults" => "15",
        "publishedAfter" => DateTime.to_iso8601(published_after),
        "key" => api_key()
      })

    case Finch.build(:get, "#{@search_url}?#{query}") |> Finch.request(@finch, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        items = Jason.decode!(body) |> Map.get("items", [])
        pick_match(items, gp_name, session_type)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The official channel + `publishedAfter` already isolate this session's video;
  # the title filter guards against the wrong session type, and the GP token is a
  # final preference so a result that fits is chosen over one that merely matches.
  defp pick_match(items, gp_name, session_type) do
    {phrases, excludes} = title_filter(session_type)
    gp_token = gp_name |> String.split() |> List.first() |> to_string() |> String.downcase()

    matches =
      Enum.filter(items, fn item ->
        title = item_title(item)
        Enum.any?(phrases, &String.contains?(title, &1)) and
          not Enum.any?(excludes, &String.contains?(title, &1))
      end)

    item =
      Enum.find(matches, fn item ->
        gp_token != "" and String.contains?(item_title(item), gp_token)
      end) || List.first(matches)

    with %{} <- item,
         vid when is_binary(vid) <- get_in(item, ["id", "videoId"]) do
      {:ok, "https://www.youtube.com/watch?v=#{vid}", get_in(item, ["snippet", "title"])}
    else
      _ -> :not_found
    end
  end

  defp item_title(item), do: item |> get_in(["snippet", "title"]) |> to_string() |> String.downcase()

  defp post(gp_name, session_type, url) do
    message = "🎬 **Highlights oficiais · #{gp_name} · #{session_type}**\n#{url}"
    F1Bot.ExternalApi.Discord.post_message({:highlights, message})
  end

  # ---- title matching -----------------------------------------------------

  defp highlights_session?(type) do
    type in ["Race", "Qualifying", "Sprint", "Sprint Qualifying", "Sprint Shootout"]
  end

  defp simple_label(type) do
    cond do
      String.contains?(type, "Sprint") -> "Sprint"
      String.contains?(type, "Qualifying") -> "Qualifying"
      String.contains?(type, "Practice") -> "Practice"
      true -> type
    end
  end

  # {accepted title phrases (any), excluded phrases (none)} — all lowercase.
  defp title_filter(type) do
    case type do
      "Race" -> {["race highlights"], ["sprint"]}
      "Qualifying" -> {["qualifying highlights"], ["sprint"]}
      "Sprint" -> {["sprint highlights"], ["qualifying", "shootout"]}
      "Sprint Qualifying" -> {["sprint qualifying highlights", "sprint shootout highlights"], []}
      "Sprint Shootout" -> {["sprint shootout highlights", "sprint qualifying highlights"], []}
      "Practice 1" -> {["practice 1 highlights", "fp1 highlights"], []}
      "Practice 2" -> {["practice 2 highlights", "fp2 highlights"], []}
      "Practice 3" -> {["practice 3 highlights", "fp3 highlights"], []}
      _ -> {["highlights"], []}
    end
  end

  # ---- config -------------------------------------------------------------

  defp api_key, do: present(F1Bot.get_env(:youtube_api_key))
  defp channel_id, do: present(F1Bot.get_env(:youtube_channel_id)) || @default_channel_id
  defp poll_minutes, do: F1Bot.get_env(:highlights_poll_minutes, 20)
  defp max_attempts, do: F1Bot.get_env(:highlights_max_attempts, 15)

  defp present(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end

  defp present(_), do: nil
end
