defmodule F1Bot.ExternalApi.F1DB do
  @moduledoc """
  Loads the F1DB dataset (https://github.com/f1db/f1db, CC-BY-4.0) — the
  "splitted" JSON release — into memory and exposes queries used by the
  calendar / next-race / teams commands.

  The dataset is downloaded once on boot (asynchronously) and refreshed
  daily. Until the first load completes, queries return `{:error, :not_loaded}`.
  """
  use GenServer
  require Logger

  @finch F1Bot.Finch
  @release_url "https://github.com/f1db/f1db/releases/latest/download/f1db-json-splitted.zip"
  @refresh_interval_ms 24 * 60 * 60 * 1000

  # Files we extract from the zip (matched by filename suffix, folder-agnostic).
  @wanted [
    races: "f1db-races.json",
    grands_prix: "f1db-grands-prix.json",
    circuits: "f1db-circuits.json",
    countries: "f1db-countries.json",
    constructors: "f1db-constructors.json",
    constructor_standings: "f1db-seasons-constructor-standings.json"
  ]

  # ---- Public API ---------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Whether the dataset has been loaded into memory."
  def loaded?, do: GenServer.call(__MODULE__, :loaded?)

  @doc "Races for the current season, enriched with GP and circuit names, sorted by round."
  def current_season_races, do: GenServer.call(__MODULE__, :current_season_races)

  @doc "The next upcoming race relative to `now` (UTC), enriched."
  def next_race(now \\ DateTime.utc_now()), do: GenServer.call(__MODULE__, {:next_race, now})

  @doc "Constructor standings for the given season year."
  def constructor_standings(year), do: GenServer.call(__MODULE__, {:constructor_standings, year})

  @doc "Force a refresh of the dataset (async)."
  def refresh, do: send(__MODULE__, :load)

  # ---- GenServer ----------------------------------------------------------

  @impl true
  def init(_) do
    # Skip network loading in backtest/demo (external APIs disabled).
    if F1Bot.get_env(:external_apis_enabled, true) do
      send(self(), :load)
    end

    {:ok, %{data: nil}}
  end

  @impl true
  def handle_info(:load, state) do
    state =
      case load_dataset() do
        {:ok, data} ->
          Logger.info("F1DB: dataset loaded (#{length(data.races)} races total)")
          %{state | data: data}

        {:error, reason} ->
          Logger.error("F1DB: failed to load dataset: #{inspect(reason)}")
          state
      end

    Process.send_after(self(), :load, @refresh_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:loaded?, _from, state), do: {:reply, state.data != nil, state}

  # Not-loaded guard for every data query.
  def handle_call(_req, _from, state = %{data: nil}),
    do: {:reply, {:error, :not_loaded}, state}

  def handle_call(:current_season_races, _from, state) do
    year = current_year(state.data)
    {:reply, {:ok, %{year: year, races: races_for_year(state.data, year)}}, state}
  end

  def handle_call({:next_race, now}, _from, state) do
    {:reply, do_next_race(state.data, now), state}
  end

  def handle_call({:constructor_standings, year}, _from, state) do
    standings =
      state.data.constructor_standings
      |> Enum.filter(&(&1["year"] == year))
      |> Enum.sort_by(&(&1["positionDisplayOrder"] || 9999))
      |> Enum.map(fn s ->
        %{
          position: s["positionText"],
          constructor: constructor_name(state.data, s["constructorId"]),
          points: s["points"]
        }
      end)

    {:reply, {:ok, %{year: year, standings: standings}}, state}
  end

  # ---- Queries ------------------------------------------------------------

  defp current_year(data) do
    today = Date.utc_today()

    years = data.races |> Enum.map(& &1["year"]) |> Enum.uniq()

    cond do
      years == [] -> today.year
      today.year in years -> today.year
      true -> Enum.max(years)
    end
  end

  defp races_for_year(data, year) do
    data.races
    |> Enum.filter(&(&1["year"] == year))
    |> Enum.sort_by(& &1["round"])
    |> Enum.map(&enrich_race(data, &1))
  end

  defp do_next_race(data, now) do
    upcoming =
      data.races
      |> Enum.filter(fn r -> race_starts_after?(r, now) end)
      |> Enum.sort_by(&race_start_datetime/1, DateTime)

    case upcoming do
      [race | _] -> {:ok, enrich_race(data, race)}
      [] -> {:error, :no_upcoming_race}
    end
  end

  # A race "counts" as upcoming until the end of its race day (so a race in
  # progress still shows as the current one).
  defp race_starts_after?(race, now) do
    case parse_date(race["date"]) do
      {:ok, date} ->
        cutoff = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")
        DateTime.compare(cutoff, now) == :gt

      :error ->
        false
    end
  end

  defp race_start_datetime(race) do
    {:ok, date} = parse_date(race["date"])
    time = parse_time(race["time"]) || ~T[12:00:00]
    DateTime.new!(date, time, "Etc/UTC")
  end

  defp enrich_race(data, race) do
    circuit = Map.get(data.circuits, race["circuitId"], %{})
    country = Map.get(data.countries, circuit["countryId"], %{})

    %{
      year: race["year"],
      round: race["round"],
      date: race["date"],
      time: race["time"],
      official_name: race["officialName"],
      grand_prix: grand_prix_name(data, race["grandPrixId"]),
      circuit: circuit["name"] || circuit["fullName"] || race["circuitId"],
      place_name: circuit["placeName"],
      country: country["name"],
      country_code: country["alpha2Code"],
      sessions: race_sessions(race)
    }
  end

  # Map of session key -> %{date, time} for sessions that have a date.
  @session_fields [
    free_practice_1: {"freePractice1Date", "freePractice1Time"},
    free_practice_2: {"freePractice2Date", "freePractice2Time"},
    free_practice_3: {"freePractice3Date", "freePractice3Time"},
    sprint_qualifying: {"sprintQualifyingDate", "sprintQualifyingTime"},
    sprint: {"sprintRaceDate", "sprintRaceTime"},
    qualifying: {"qualifyingDate", "qualifyingTime"},
    race: {"date", "time"}
  ]

  defp race_sessions(race) do
    for {key, {date_field, time_field}} <- @session_fields,
        date = race[date_field],
        date != nil,
        into: %{} do
      {key, %{date: date, time: race[time_field]}}
    end
  end

  defp grand_prix_name(data, id), do: lookup_name(data.grands_prix, id)
  defp constructor_name(data, id), do: lookup_name(data.constructors, id)

  defp lookup_name(index, id) do
    case Map.get(index, id) do
      nil -> id
      entry -> entry["name"] || entry["fullName"] || id
    end
  end

  # ---- Loading ------------------------------------------------------------

  defp load_dataset do
    with {:ok, zip_binary} <- download(@release_url, 5),
         {:ok, files} <- unzip(zip_binary),
         {:ok, parsed} <- parse_wanted(files) do
      data =
        parsed
        |> Map.update!(:grands_prix, &index_by_id/1)
        |> Map.update!(:circuits, &index_by_id/1)
        |> Map.update!(:countries, &index_by_id/1)
        |> Map.update!(:constructors, &index_by_id/1)

      {:ok, data}
    end
  end

  defp download(_url, 0), do: {:error, :too_many_redirects}

  defp download(url, redirects_left) do
    case Finch.build(:get, url, [{"user-agent", "f1bot"}]) |> Finch.request(@finch, receive_timeout: 30_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, headers: headers}} when status in [301, 302, 303, 307, 308] ->
        case List.keyfind(headers, "location", 0) do
          {_, location} -> download(location, redirects_left - 1)
          nil -> {:error, {:redirect_without_location, status}}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unzip(zip_binary) do
    case :zip.unzip(zip_binary, [:memory]) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, {:unzip_failed, reason}}
    end
  end

  # files :: [{charlist_name, binary_content}]
  defp parse_wanted(files) do
    Enum.reduce_while(@wanted, {:ok, %{}}, fn {key, suffix}, {:ok, acc} ->
      case find_file(files, suffix) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
            {:error, err} -> {:halt, {:error, {:json_decode, suffix, err}}}
          end

        :error ->
          {:halt, {:error, {:file_missing, suffix}}}
      end
    end)
  end

  defp find_file(files, suffix) do
    Enum.find_value(files, :error, fn {name, content} ->
      if String.ends_with?(to_string(name), suffix), do: {:ok, content}, else: nil
    end)
  end

  defp index_by_id(list) when is_list(list) do
    Map.new(list, fn entry -> {entry["id"], entry} end)
  end

  # ---- Date/time helpers --------------------------------------------------

  defp parse_date(nil), do: :error
  defp parse_date(str) when is_binary(str), do: Date.from_iso8601(str) |> normalize_ok()

  defp parse_time(nil), do: nil

  defp parse_time(str) when is_binary(str) do
    case Time.from_iso8601(str) do
      {:ok, time} -> time
      _ -> nil
    end
  end

  defp normalize_ok({:ok, v}), do: {:ok, v}
  defp normalize_ok(_), do: :error
end
