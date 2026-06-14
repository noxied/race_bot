defmodule F1Bot.F1Session.LiveTimingHandlers.TimingData do
  @moduledoc """
  Handler for lap times and sector times received from live timing API.
  The handler parses drivers' information and passes it on to the F1 session instance.
  """
  use TypedStruct

  require Logger
  alias F1Bot.F1Session.LiveTimingHandlers
  import LiveTimingHandlers.Helpers

  alias F1Bot.F1Session
  alias F1Bot.DataTransform.Parse
  alias LiveTimingHandlers.{Packet, ProcessingResult}

  @type sector_times :: %{
          optional(1) => Timex.Duration.t(),
          optional(2) => Timex.Duration.t(),
          optional(3) => Timex.Duration.t()
        }

  typedstruct do
    field(:driver_number, pos_integer(), enforce: true)
    field(:timestamp, DateTime.t(), enforce: true)
    field(:lap_number, pos_integer() | nil)
    field(:lap_time, Timex.Duration.t() | nil)
    field(:sector_times, sector_times() | nil)
    # Live running order (deltas are partial, merged into session state downstream)
    field(:position, pos_integer() | nil)
    field(:gap_to_leader, String.t() | nil)
    field(:interval, String.t() | nil)
    field(:in_pit, boolean() | nil)
    field(:retired, boolean() | nil)
  end

  @behaviour LiveTimingHandlers
  @scope "TimingData"

  @impl F1Bot.F1Session.LiveTimingHandlers
  def process_packet(
        session,
        %Packet{
          topic: @scope,
          data: %{"Lines" => drivers = %{}},
          timestamp: timestamp,
          init: init
        },
        options
      ) do
    lines =
      drivers
      |> Enum.map(fn {num_str, data} -> {parse_driver_number(num_str), data} end)
      |> Enum.filter(fn {driver_number, _data} -> driver_number != nil end)

    {session, events} =
      if init do
        # Reconnect snapshot: refresh the running order (positions/gaps) only.
        # No lap replay and no events, so it just corrects /positions without
        # re-posting anything.
        timing_data_list =
          Enum.map(lines, fn {driver_number, data} ->
            build_timing_data(driver_number, data, timestamp)
          end)

        {F1Session.refresh_live_timing(session, timing_data_list), []}
      else
        push_lines(session, lines, timestamp, options)
      end

    {:ok, %ProcessingResult{session: session, events: events}}
  end

  @impl F1Bot.F1Session.LiveTimingHandlers
  def process_packet(_session, _invalid_packet, _options) do
    {:error, :invalid_packet}
  end

  defp push_lines(session, lines, timestamp, options) do
    {session, events_nested} =
      Enum.reduce(lines, {session, []}, fn {driver_number, data}, {session, events} ->
        maybe_log_driver_data("TimingData", driver_number, {timestamp, data}, options)
        timing_data = build_timing_data(driver_number, data, timestamp)

        {session, new_events} =
          F1Session.push_timing_data(session, timing_data, !!options.skip_heavy_events)

        {session, [new_events | events]}
      end)

    {session, List.flatten(events_nested)}
  end

  defp parse_driver_number(num_str) do
    case Integer.parse(num_str) do
      {driver_number, ""} -> driver_number
      _ -> nil
    end
  end

  defp build_timing_data(driver_number, data, timestamp) do
    %__MODULE__{
      driver_number: driver_number,
      timestamp: timestamp,
      lap_number: data["NumberOfLaps"],
      lap_time: maybe_extract_lap_time(data),
      sector_times: maybe_extract_sectors(data),
      position: parse_position(data["Position"]),
      gap_to_leader: blank_to_nil(data["GapToLeader"]),
      interval: blank_to_nil(get_in(data, ["IntervalToPositionAhead", "Value"])),
      in_pit: data["InPit"],
      retired: data["Retired"]
    }
  end

  defp maybe_extract_lap_time(data) do
    lap_time_str = data["LastLapTime"]["Value"]

    if lap_time_str != nil and lap_time_str != "" do
      case Parse.parse_lap_time(lap_time_str) do
        {:ok, lap_time} ->
          lap_time

        {:error, _error} ->
          Logger.error("Error parsing lap time #{inspect(lap_time_str)}")
          nil
      end
    else
      nil
    end
  end

  def maybe_extract_sectors(_data = %{"Sectors" => sectors = %{}}) do
    result =
      ["0", "1", "2"]
      |> Enum.reduce(%{}, fn sector_str, acc ->
        sector_time_str = sectors[sector_str]["Value"]
        sector = String.to_integer(sector_str) + 1

        with true <- is_binary(sector_time_str),
             true <- sector_time_str != "",
             {:ok, sector_time} <- Parse.parse_lap_time(sector_time_str) do
          Map.put(acc, sector, sector_time)
        else
          {:error, _error} ->
            Logger.error("Error parsing sector time #{inspect(sector_time_str)}")
            acc

          _ ->
            acc
        end
      end)

    if result == %{} do
      nil
    else
      result
    end
  end

  def maybe_extract_sectors(_sectors), do: nil

  defp parse_position(p) when is_integer(p) and p > 0, do: p

  defp parse_position(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_position(_), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      other -> other
    end
  end

  defp blank_to_nil(_), do: nil
end
