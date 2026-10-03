defmodule F1Bot.Highlights do
  @moduledoc """
  YouTube lookup and local catalogue for official session highlights.

  Searches the official channel for a given series (F1/F2/F3), matches the video
  for a session by title, and stores what it finds in the `highlights` table so
  later lookups (and the planned `!highlights` command) can be served from the DB
  without spending API quota.
  """
  require Logger
  import Ecto.Query
  alias F1Bot.Repo
  alias F1Bot.Highlights.Video

  @search_url "https://www.googleapis.com/youtube/v3/search"
  # Official FORMULA 1 channel; overridable with YOUTUBE_CHANNEL_ID.
  @default_f1_channel_id "UCB_qr75-ydFVKSF9Dmo6izg"
  @finch F1Bot.Finch

  # ---- config -------------------------------------------------------------

  def api_key, do: present(F1Bot.get_env(:youtube_api_key))
  def poll_minutes, do: F1Bot.get_env(:highlights_poll_minutes, 20)
  def max_attempts, do: F1Bot.get_env(:highlights_max_attempts, 15)

  @doc "YouTube channel id for a series (F1/F2/F3); nil if not configured."
  def channel_for_series(series) do
    case series |> to_string() |> String.upcase() do
      "F2" -> present(F1Bot.get_env(:youtube_channel_id_f2))
      "F3" -> present(F1Bot.get_env(:youtube_channel_id_f3))
      _ -> present(F1Bot.get_env(:youtube_channel_id)) || @default_f1_channel_id
    end
  end

  # ---- lookup for a known session (used by the live worker) ---------------

  @doc """
  Finds the highlights video for a finalised session. Returns `{:ok, attrs}`
  (ready for `upsert/1`), `:not_found`, or `{:error, reason}`.
  """
  def find_for_session(series, gp_name, session_type, published_after) do
    with key when is_binary(key) <- api_key(),
         ch when is_binary(ch) <- channel_for_series(series),
         query = "#{gp_name} #{simple_label(session_type)} highlights",
         {:ok, items} <- search_raw(ch, query, published_after, 15, key),
         %{} = item <- pick_match(items, gp_name, session_type) do
      attrs = base_attrs(item, series) |> Map.merge(%{gp_name: gp_name, session_type: session_type})
      {:ok, attrs}
    else
      :not_found -> :not_found
      {:error, _} = error -> error
      nil -> {:error, :not_configured}
      _ -> :not_found
    end
  end

  # ---- catalogue (DB) -----------------------------------------------------

  @doc "Stores a video, ignoring it if the video id is already catalogued."
  def upsert(attrs) do
    %Video{}
    |> Video.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :video_id)
  end

  @doc "Most recently published catalogued video for a series."
  def latest(series \\ "F1") do
    Video
    |> where([v], v.series == ^series)
    |> order_by([v], desc: v.published_at, desc: v.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Catalogued videos for a GP (and year/series), oldest first."
  def lookup(series, gp_name, year) do
    pattern = "%#{gp_name}%"

    Video
    |> where([v], v.series == ^series and v.year == ^year)
    |> where([v], like(v.gp_name, ^pattern))
    |> order_by([v], asc: v.published_at)
    |> Repo.all()
  end

  @doc """
  Backfills the catalogue from the channel's recent uploads (default last 45
  days), parsing the session and GP from each title. Returns `{:ok, list}` of
  `{gp_name, session_type, url}` catalogued. Run once per instance from iex.
  """
  def backfill(series \\ "F1", opts \\ []) do
    days = Keyword.get(opts, :days, 45)

    with key when is_binary(key) <- api_key(),
         ch when is_binary(ch) <- channel_for_series(series) do
      published_after =
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-days * 86_400, :second)

      case search_raw(ch, "highlights", published_after, 50, key) do
        {:ok, items} ->
          cataloged =
            items
            |> Enum.map(fn item ->
              attrs = base_attrs(item, series)

              case parse_title(attrs.title) do
                {session, gp} -> Map.merge(attrs, %{session_type: session, gp_name: gp})
                nil -> nil
              end
            end)
            |> Enum.reject(&(is_nil(&1) or is_nil(&1.video_id)))

          Enum.each(cataloged, &upsert/1)
          Logger.info("[HIGHLIGHTS] backfill #{series}: #{length(cataloged)} videos cataloged")
          {:ok, Enum.map(cataloged, &{&1.gp_name, &1.session_type, &1.url})}

        error ->
          error
      end
    else
      _ -> {:error, :not_configured}
    end
  end

  # ---- youtube ------------------------------------------------------------

  defp search_raw(channel_id, query, published_after, max, key) do
    params =
      URI.encode_query(%{
        "part" => "snippet",
        "channelId" => channel_id,
        "q" => query,
        "type" => "video",
        "order" => "date",
        "maxResults" => to_string(max),
        "publishedAfter" => DateTime.to_iso8601(published_after),
        "key" => key
      })

    case Finch.build(:get, "#{@search_url}?#{params}") |> Finch.request(@finch, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body) |> Map.get("items", [])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp base_attrs(item, series) do
    video_id = get_in(item, ["id", "videoId"])
    title = item |> get_in(["snippet", "title"]) |> to_string()
    published_at = item |> get_in(["snippet", "publishedAt"]) |> parse_dt()

    %{
      series: series,
      video_id: video_id,
      url: video_id && "https://www.youtube.com/watch?v=#{video_id}",
      title: title,
      published_at: published_at,
      year: year_from_title(title) || (published_at && published_at.year)
    }
  end

  # ---- title matching -----------------------------------------------------

  # The official channel + publishedAfter already isolate the session's video;
  # the title filter guards the session type, and the GP token is a final
  # preference so a fitting result is chosen over one that merely matches.
  defp pick_match(items, gp_name, session_type) do
    {phrases, excludes} = title_filter(session_type)
    gp_token = gp_name |> String.split() |> List.first() |> to_string() |> String.downcase()

    matches =
      Enum.filter(items, fn item ->
        title = item_title(item)

        is_binary(get_in(item, ["id", "videoId"])) and
          Enum.any?(phrases, &String.contains?(title, &1)) and
          not Enum.any?(excludes, &String.contains?(title, &1))
      end)

    Enum.find(matches, fn item -> gp_token != "" and String.contains?(item_title(item), gp_token) end) ||
      List.first(matches) || :not_found
  end

  defp item_title(item), do: item |> get_in(["snippet", "title"]) |> to_string() |> String.downcase()

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

  defp simple_label(type) do
    cond do
      String.contains?(type, "Sprint") -> "Sprint"
      String.contains?(type, "Qualifying") -> "Qualifying"
      String.contains?(type, "Practice") -> "Practice"
      true -> type
    end
  end

  # Parse the session and GP from a highlights title, e.g.
  # "Race Highlights | 2026 Bahrain Grand Prix in Malaysia". nil when it is not a
  # recognised session highlights clip.
  defp parse_title(title) do
    lower = String.downcase(title)
    session = session_from_title(lower)

    if session != nil and String.contains?(lower, "highlights") do
      {session, gp_from_title(title)}
    else
      nil
    end
  end

  defp session_from_title(lower) do
    cond do
      String.contains?(lower, "sprint qualifying") or String.contains?(lower, "sprint shootout") ->
        "Sprint Qualifying"

      String.contains?(lower, "sprint") -> "Sprint"
      String.contains?(lower, "qualifying") -> "Qualifying"
      String.contains?(lower, "race highlights") -> "Race"
      String.contains?(lower, "fp1") or String.contains?(lower, "practice 1") -> "Practice 1"
      String.contains?(lower, "fp2") or String.contains?(lower, "practice 2") -> "Practice 2"
      String.contains?(lower, "fp3") or String.contains?(lower, "practice 3") -> "Practice 3"
      true -> nil
    end
  end

  defp gp_from_title(title) do
    base =
      case String.split(title, "|", parts: 2) do
        [_prefix, rest] -> rest
        [only] -> only
      end

    base
    |> String.replace(~r/\b20\d{2}\b/, "")
    |> String.replace(~r/highlights/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp year_from_title(title) do
    case Regex.run(~r/\b(20\d{2})\b/, title) do
      [_, year] -> String.to_integer(year)
      _ -> nil
    end
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp present(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end

  defp present(_), do: nil
end
