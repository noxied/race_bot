defmodule F1Bot.Highlights do
  @moduledoc """
  YouTube lookup and local catalogue for official session highlights.

  The official FORMULA 1 channel hosts F1, F2 and F3 highlights, so the series is
  detected from the video title. The live worker catalogues F1 sessions as they
  finalise; `backfill/1` catalogues every series' recent highlights from the same
  channel. Stored rows serve later lookups (and the planned `!highlights`
  command) without spending API quota.
  """
  require Logger
  import Ecto.Query
  alias F1Bot.Repo
  alias F1Bot.Highlights.Video

  @search_url "https://www.googleapis.com/youtube/v3/search"
  # Official FORMULA 1 channel; overridable with YOUTUBE_CHANNEL_ID. It also hosts
  # F2/F3, so F2/F3 fall back to it unless given their own channel id.
  @default_f1_channel_id "UCB_qr75-ydFVKSF9Dmo6izg"
  @finch F1Bot.Finch

  # ---- config -------------------------------------------------------------

  def api_key, do: present(F1Bot.get_env(:youtube_api_key))
  def poll_minutes, do: F1Bot.get_env(:highlights_poll_minutes, 20)
  def max_attempts, do: F1Bot.get_env(:highlights_max_attempts, 15)

  @doc "YouTube channel id for a series; F2/F3 default to the F1 channel."
  def channel_for_series(series) do
    default = present(F1Bot.get_env(:youtube_channel_id)) || @default_f1_channel_id

    case series |> to_string() |> String.upcase() do
      "F2" -> present(F1Bot.get_env(:youtube_channel_id_f2)) || default
      "F3" -> present(F1Bot.get_env(:youtube_channel_id_f3)) || default
      _ -> default
    end
  end

  # ---- lookup for a known session (used by the live worker) ---------------

  @doc """
  Finds the highlights video for a finalised session. Returns `{:ok, attrs}`
  (ready for `upsert/1`), `:not_found`, or `{:error, reason}`. Only videos whose
  title matches the given series are considered.
  """
  def find_for_session(series, gp_name, session_type, published_after) do
    with key when is_binary(key) <- api_key(),
         ch when is_binary(ch) <- channel_for_series(series),
         query = "#{gp_name} #{simple_label(session_type)} highlights",
         {:ok, items} <- search_raw(ch, query, published_after, 15, key),
         %{} = item <- pick_match(items, series, gp_name, session_type) do
      attrs =
        base_attrs(item)
        |> Map.merge(%{series: series, gp_name: gp_name, session_type: session_type})

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

  @doc "Catalogued videos for a GP (and year/series), oldest first."
  def lookup(series, gp_name, year) do
    pattern = "%#{gp_name}%"

    Video
    |> where([v], v.series == ^series and v.year == ^year)
    |> where([v], like(v.gp_name, ^pattern))
    |> order_by([v], asc: v.published_at)
    |> Repo.all()
  end

  @doc "Most recently published catalogued video across all series, or nil."
  def latest_overall do
    # ecto_sqlite3 0.9.1 raises on `limit`, so order in SQL and take the head.
    Video
    |> order_by([v], desc: v.published_at, desc: v.inserted_at)
    |> Repo.all()
    |> List.first()
  end

  @doc """
  Highlights for a GP: the catalogue first, else a YouTube search (results are
  catalogued). Returns `{:ok, :cache | :youtube, videos}`, `:not_found`, or
  `{:error, reason}`. `videos` are maps with series/gp_name/session_type/url.
  """
  def find_gp(series, gp_name, year) do
    case lookup(series, gp_name, year) do
      [] -> search_gp(series, gp_name, year)
      videos -> {:ok, :cache, Enum.map(videos, &video_to_map/1)}
    end
  end

  defp search_gp(series, gp_name, year) do
    with key when is_binary(key) <- api_key(),
         ch when is_binary(ch) <- channel_for_series(series),
         {:ok, items} <- search_raw(ch, "#{gp_name} #{year} highlights", nil, 25, key, "relevance") do
      results =
        items
        |> Enum.map(fn item ->
          attrs = base_attrs(item)

          case parse_title(attrs.title) do
            {s, session, gp} -> Map.merge(attrs, %{series: s, session_type: session, gp_name: gp})
            nil -> nil
          end
        end)
        |> Enum.reject(&(is_nil(&1) or is_nil(&1.video_id)))
        |> Enum.filter(fn a -> a.series == series and a.year == year and gp_match?(a.gp_name, gp_name) end)

      Enum.each(results, &upsert/1)
      if results == [], do: :not_found, else: {:ok, :youtube, results}
    else
      nil -> {:error, :not_configured}
      {:error, _} = error -> error
      _ -> :not_found
    end
  end

  defp video_to_map(%Video{} = v) do
    %{
      series: v.series,
      gp_name: v.gp_name,
      session_type: v.session_type,
      url: v.url,
      title: v.title,
      published_at: v.published_at
    }
  end

  defp gp_match?(a, b) do
    a = String.downcase(a || "")
    b = String.downcase(b || "")
    b != "" and (String.contains?(a, b) or String.contains?(b, a))
  end

  @doc """
  Backfills the catalogue from the channel's recent uploads (default last 45
  days), detecting the series, session and GP from each title. Covers F1/F2/F3.
  Returns `{:ok, list}` of `{series, gp_name, session_type, url}`. Run once per
  instance from iex.
  """
  def backfill(opts \\ []) do
    days = Keyword.get(opts, :days, 45)

    with key when is_binary(key) <- api_key(),
         ch when is_binary(ch) <- channel_for_series("F1") do
      published_after =
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-days * 86_400, :second)

      case search_raw(ch, "highlights", published_after, 50, key) do
        {:ok, items} ->
          cataloged =
            items
            |> Enum.map(fn item ->
              attrs = base_attrs(item)

              case parse_title(attrs.title) do
                {series, session, gp} ->
                  Map.merge(attrs, %{series: series, session_type: session, gp_name: gp})

                nil ->
                  nil
              end
            end)
            |> Enum.reject(&(is_nil(&1) or is_nil(&1.video_id)))

          Enum.each(cataloged, &upsert/1)
          Logger.info("[HIGHLIGHTS] backfill: #{length(cataloged)} videos cataloged")
          {:ok, Enum.map(cataloged, &{&1.series, &1.gp_name, &1.session_type, &1.url})}

        error ->
          error
      end
    else
      _ -> {:error, :not_configured}
    end
  end

  # ---- youtube ------------------------------------------------------------

  defp search_raw(channel_id, query, published_after, max, key, order \\ "date") do
    params =
      %{
        "part" => "snippet",
        "channelId" => channel_id,
        "q" => query,
        "type" => "video",
        "order" => order,
        "maxResults" => to_string(max),
        "key" => key
      }
      |> maybe_put("publishedAfter", published_after && DateTime.to_iso8601(published_after))
      |> URI.encode_query()

    case Finch.build(:get, "#{@search_url}?#{params}") |> Finch.request(@finch, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body) |> Map.get("items", [])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp base_attrs(item) do
    video_id = get_in(item, ["id", "videoId"])
    title = item |> get_in(["snippet", "title"]) |> to_string()
    published_at = item |> get_in(["snippet", "publishedAt"]) |> parse_dt()

    %{
      video_id: video_id,
      url: video_id && "https://www.youtube.com/watch?v=#{video_id}",
      title: title,
      published_at: published_at,
      year: year_from_title(title) || (published_at && published_at.year)
    }
  end

  # ---- title matching -----------------------------------------------------

  # The channel + publishedAfter isolate the session's video; the series and
  # title filters guard against F2/F3 clips and the wrong session type, and the
  # GP token is a final preference.
  defp pick_match(items, series, gp_name, session_type) do
    {phrases, excludes} = title_filter(session_type)
    gp_token = gp_name |> String.split() |> List.first() |> to_string() |> String.downcase()

    matches =
      Enum.filter(items, fn item ->
        title = item_title(item)

        is_binary(get_in(item, ["id", "videoId"])) and
          detect_series(title) == series and
          Enum.any?(phrases, &String.contains?(title, &1)) and
          not Enum.any?(excludes, &String.contains?(title, &1))
      end)

    Enum.find(matches, fn item -> gp_token != "" and String.contains?(item_title(item), gp_token) end) ||
      List.first(matches) || :not_found
  end

  defp item_title(item), do: item |> get_in(["snippet", "title"]) |> to_string() |> String.downcase()

  # Series from a (lowercased) title; the F1 channel also posts F2/F3 clips.
  defp detect_series(lower_title) do
    cond do
      lower_title =~ ~r/\bf3\b/ or String.contains?(lower_title, "formula 3") -> "F3"
      lower_title =~ ~r/\bf2\b/ or String.contains?(lower_title, "formula 2") -> "F2"
      true -> "F1"
    end
  end

  # {accepted title phrases (any), excluded phrases (none)} — all lowercase. Used
  # for the live F1 worker; series filtering keeps F2/F3 clips out separately.
  defp title_filter(type) do
    case type do
      "Race" -> {["race highlights"], ["sprint"]}
      "Qualifying" -> {["qualifying highlights"], ["sprint"]}
      "Sprint" -> {["sprint highlights"], ["qualifying", "shootout"]}
      "Sprint Qualifying" -> {["sprint qualifying highlights", "sprint shootout highlights"], []}
      "Sprint Shootout" -> {["sprint shootout highlights", "sprint qualifying highlights"], []}
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

  # Parse {series, session, gp} from a highlights title, or nil when it is not a
  # recognised session highlights clip. Handles F1 and F2/F3 session names.
  defp parse_title(title) do
    lower = String.downcase(title)
    series = detect_series(lower)
    session = session_from_title(lower)

    if session != nil and String.contains?(lower, "highlights") do
      {series, session, gp_from_title(title)}
    else
      nil
    end
  end

  defp session_from_title(lower) do
    cond do
      String.contains?(lower, "sprint qualifying") or String.contains?(lower, "sprint shootout") ->
        "Sprint Qualifying"

      String.contains?(lower, "feature race") -> "Feature Race" <> race_num(lower, "feature race")
      String.contains?(lower, "sprint race") -> "Sprint Race" <> race_num(lower, "sprint race")
      String.contains?(lower, "sprint") -> "Sprint"
      String.contains?(lower, "qualifying") -> "Qualifying"
      String.contains?(lower, "race highlights") -> "Race"
      String.contains?(lower, "fp1") or String.contains?(lower, "practice 1") -> "Practice 1"
      String.contains?(lower, "fp2") or String.contains?(lower, "practice 2") -> "Practice 2"
      String.contains?(lower, "fp3") or String.contains?(lower, "practice 3") -> "Practice 3"
      String.contains?(lower, "practice") -> "Practice"
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

  # A trailing number on a Feature/Sprint Race (double-headers), e.g. " 2".
  defp race_num(lower, phrase) do
    case Regex.run(~r/#{phrase}\s+(\d+)/, lower) do
      [_, n] -> " " <> n
      _ -> ""
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
