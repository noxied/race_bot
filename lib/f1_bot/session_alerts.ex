defmodule F1Bot.SessionAlerts do
  @moduledoc """
  Posts a heads-up to the Discord messages channel a configurable number of
  minutes before each main F1 session (qualifying, sprint, race) starts.

  Offsets come from the `:session_alert_minutes` config (env
  `SESSION_ALERT_MINUTES`, e.g. "60,30,15"); an empty list disables alerts.
  Session times come from `F1Bot.ExternalApi.F1Calendar` (the ICS feed).
  """
  use GenServer
  require Logger
  alias F1Bot.ExternalApi.{F1Calendar, Discord}

  @tick_ms 60_000
  @main_kinds [:qualifying, :sprint, :sprint_qualifying, :race]

  # Fire only within this window (seconds) after the offset threshold is crossed.
  # Combined with the per-(session, offset) dedup set this fires each alert once
  # and avoids re-firing stale alerts after a restart without persistence.
  @window_sec 70

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    offsets = F1Bot.get_env(:session_alert_minutes, [60, 30, 15])

    if offsets != [] and F1Bot.get_env(:external_apis_enabled, true) do
      Logger.info("SessionAlerts: enabled, offsets (min): #{inspect(offsets)}")
      :timer.send_interval(@tick_ms, :tick)
      {:ok, %{offsets: offsets, fired: MapSet.new()}}
    else
      Logger.info("SessionAlerts: disabled")
      {:ok, %{offsets: [], fired: MapSet.new()}}
    end
  end

  @impl true
  def handle_info(:tick, state = %{offsets: []}), do: {:noreply, state}

  def handle_info(:tick, state) do
    now = DateTime.utc_now()
    sessions = F1Calendar.upcoming(@main_kinds, now)

    fired =
      for session <- sessions, offset <- state.offsets, reduce: state.fired do
        acc -> maybe_fire(session, offset, now, acc)
      end

    {:noreply, %{state | fired: fired}}
  end

  defp maybe_fire(session, offset_min, now, fired) do
    key = {session.summary, offset_min}
    target = offset_min * 60
    secs_until = DateTime.diff(session.start, now)

    if secs_until <= target and secs_until > target - @window_sec and
         not MapSet.member?(fired, key) do
      post_alert(session)
      MapSet.put(fired, key)
    else
      fired
    end
  end

  defp post_alert(session) do
    unix = DateTime.to_unix(session.start)
    msg = "⏰ **#{label(session.kind)}** (#{session.gp_name}) <t:#{unix}:R> · <t:#{unix}:t>"
    Discord.post_message(msg)
  end

  defp label(:qualifying), do: "Qualifying"
  defp label(:sprint), do: "Sprint"
  defp label(:sprint_qualifying), do: "Sprint Qualifying"
  defp label(:race), do: "Race"
  defp label(other), do: other |> to_string() |> String.capitalize()
end
