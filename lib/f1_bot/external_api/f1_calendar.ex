defmodule F1Bot.ExternalApi.F1Calendar do
  @moduledoc """
  Fetches and parses the F1 session calendar (ICS feed from
  motorsportcalendars.com) to obtain exact session start times, which f1db does
  not provide for upcoming seasons. Used for session-start alerts.

  Loaded on boot (asynchronously) and refreshed every few hours. Skipped when
  external APIs are disabled (backtest).
  """
  use GenServer
  require Logger

  @finch F1Bot.Finch
  @ics_url "https://files-f1.motorsportcalendars.com/f1-calendar_p1_p2_p3_qualifying_sprint_gp.ics"
  @refresh_interval_ms 6 * 60 * 60 * 1000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "All parsed sessions, sorted by start time."
  def sessions, do: GenServer.call(__MODULE__, :sessions)

  @doc "Upcoming sessions of the given kinds (atoms) that start after `now`."
  def upcoming(kinds, now \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:upcoming, kinds, now})
  end

  @impl true
  def init(_) do
    if F1Bot.get_env(:external_apis_enabled, true), do: send(self(), :load)
    {:ok, %{sessions: []}}
  end

  @impl true
  def handle_info(:load, state) do
    state =
      case load() do
        {:ok, sessions} ->
          Logger.info("F1Calendar: loaded #{length(sessions)} sessions")
          %{state | sessions: sessions}

        {:error, reason} ->
          Logger.error("F1Calendar: failed to load: #{inspect(reason)}")
          state
      end

    Process.send_after(self(), :load, @refresh_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sessions, _from, state), do: {:reply, state.sessions, state}

  def handle_call({:upcoming, kinds, now}, _from, state) do
    result =
      state.sessions
      |> Enum.filter(fn s -> s.kind in kinds and DateTime.compare(s.start, now) == :gt end)
      |> Enum.sort_by(& &1.start, DateTime)

    {:reply, result, state}
  end

  # ---- Loading & parsing --------------------------------------------------

  defp load do
    case Finch.build(:get, @ics_url, [{"user-agent", "f1bot"}])
         |> Finch.request(@finch, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse(body)}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(ics) do
    ics
    |> unfold()
    |> String.split("BEGIN:VEVENT")
    |> Enum.drop(1)
    |> Enum.map(&parse_event/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.start, DateTime)
  end

  # Unfold RFC 5545 line folding (continuation lines start with a space/tab).
  defp unfold(ics) do
    ics
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/\n[ \t]/, "")
  end

  defp parse_event(block) do
    with summary when is_binary(summary) <- extract(block, "SUMMARY"),
         dtstart when is_binary(dtstart) <- extract(block, "DTSTART"),
         {:ok, start} <- parse_dt(dtstart),
         {kind, gp} <- parse_summary(summary) do
      %{kind: kind, gp_name: gp, start: start, summary: summary}
    else
      _ -> nil
    end
  end

  defp extract(block, key) do
    block
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, key) do
        case String.split(line, ":", parts: 2) do
          [_, value] -> String.trim(value)
          _ -> nil
        end
      end
    end)
  end

  # "20260306T013000Z" -> DateTime (UTC).
  defp parse_dt(
         <<y::binary-4, mo::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2,
           "Z">>
       ) do
    with {:ok, date} <- Date.from_iso8601("#{y}-#{mo}-#{d}"),
         {:ok, time} <- Time.from_iso8601("#{h}:#{mi}:#{s}") do
      {:ok, DateTime.new!(date, time, "Etc/UTC")}
    else
      _ -> :error
    end
  end

  defp parse_dt(_), do: :error

  # "F1: FP1 (Australian Grand Prix)" -> {:fp1, "Australian Grand Prix"}
  defp parse_summary(summary) do
    case Regex.run(~r/^F1:\s*(.+?)\s*\((.+)\)\s*$/u, summary) do
      [_, type, gp] -> {classify(type), gp}
      _ -> nil
    end
  end

  defp classify(type) do
    t = String.downcase(type)

    cond do
      String.contains?(t, "sprint") and String.contains?(t, "qual") -> :sprint_qualifying
      String.contains?(t, "sprint") -> :sprint
      String.contains?(t, "qual") -> :qualifying
      String.contains?(t, "fp1") or String.contains?(t, "practice 1") -> :fp1
      String.contains?(t, "fp2") or String.contains?(t, "practice 2") -> :fp2
      String.contains?(t, "fp3") or String.contains?(t, "practice 3") -> :fp3
      String.contains?(t, "race") or String.contains?(t, "grand prix") or String.contains?(t, "gp") -> :race
      true -> :other
    end
  end
end
