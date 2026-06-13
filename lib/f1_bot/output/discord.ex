defmodule F1Bot.Output.Discord do
  @moduledoc """
  Listens for events published by `F1Bot.F1Session.Server`, composes messages for Discord
  and calls a configured Discord client (live or console) to send them.
  """
  use GenServer
  require Logger

  alias F1Bot.Output.Common
  alias F1Bot.DelayedEvents
  alias F1Bot.DataTransform.Format
  alias F1Bot.F1Session.DriverDataRepo.Transcript

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: server_via())
  end

  @impl true
  def init(_init_arg) do
    {:ok, _topics} =
      DelayedEvents.subscribe_with_delay(
        [
          "aggregate_stats:fastest_lap",
          "aggregate_stats:fastest_sector",
          "aggregate_stats:top_speed",
          "driver:tyre_change",
          "driver:transcript",
          "session_status:started",
          "race_control:message"
        ],
        25_000,
        false
      )

    state = %{session_type: nil, segments_done: 0}

    {:ok, state}
  end

  @impl true
  def handle_info(
        e = %{
          scope: "aggregate_stats:fastest_lap",
          payload: %{
            driver_number: driver_number,
            lap_time: lap_time,
            lap_delta: lap_delta,
            type: overall_or_personal
          }
        },
        state
      ) do
    if Common.should_post_stats(e) and overall_or_personal == :overall do
      driver = Common.get_driver_name_by_number(e, driver_number)

      lap_time = Format.format_lap_time(lap_time)
      lap_delta = Format.format_lap_delta(lap_delta)

      emoji =
        case overall_or_personal do
          :overall -> F1Bot.ExternalApi.Discord.get_emoji_or_default(:quick, ":zap:")
          :personal -> F1Bot.ExternalApi.Discord.get_emoji_or_default(:timer, ":comet:")
        end

      type =
        case overall_or_personal do
          :overall -> "#{emoji}  **Fastest Lap**"
          :personal -> "#{emoji}  **Personal Fastest Lap**"
        end

      msg = "#{type}: `#{driver}` of `#{lap_time}` `(#{lap_delta})`"

      F1Bot.ExternalApi.Discord.post_message(msg)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        e = %{
          scope: "aggregate_stats:fastest_sector",
          payload: %{
            driver_number: driver_number,
            sector: sector,
            sector_time: sector_time,
            sector_delta: sector_delta,
            type: fastest_type
          }
        },
        state
      )
      when sector_delta != nil do
    if Common.should_post_stats(e) and fastest_type == :overall do
      driver = Common.get_driver_name_by_number(e, driver_number)

      sector_time = Format.format_lap_time(sector_time)
      sector_delta = Format.format_lap_delta(sector_delta)

      emoji = F1Bot.ExternalApi.Discord.get_emoji_or_default(:quick, ":zap:")
      type = "#{emoji}  **Fastest Sector #{sector}**"

      msg = "#{type}: `#{driver}` of `#{sector_time}` `(#{sector_delta})`"

      F1Bot.ExternalApi.Discord.post_message(msg)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        e = %{
          scope: "aggregate_stats:top_speed",
          payload: %{
            driver_number: driver_number,
            speed: speed,
            speed_delta: speed_delta,
            type: overall_or_personal
          }
        },
        state
      ) do
    if overall_or_personal == :overall do
      driver = Common.get_driver_name_by_number(e, driver_number)

      emoji =
        case overall_or_personal do
          :overall -> F1Bot.ExternalApi.Discord.get_emoji_or_default(:quick, ":zap:")
          :personal -> F1Bot.ExternalApi.Discord.get_emoji_or_default(:speedometer, ":comet:")
        end

      type =
        case overall_or_personal do
          :overall -> "#{emoji}  **Overall Top Speed**"
          :personal -> "#{emoji}  **Personal Top Speed**"
        end

      msg = "#{type}: `#{driver}` of `#{speed} km/h` `(+#{speed_delta} km/h)`"
      F1Bot.ExternalApi.Discord.post_message(msg)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        e = %{
          scope: "driver:tyre_change",
          meta: %{
            session_status: session_status
          },
          payload: %{
            driver_number: driver_number,
            is_correction: is_correction,
            compound: compound,
            age: age
          }
        },
        state
      ) do
    if session_status == :started do
      driver = Common.get_driver_name_by_number(e, driver_number)

      age_str =
        if age == 0 do
          "New"
        else
          "#{age} laps old"
        end

      correction =
        if is_correction do
          " (correction)"
        end

      emoji =
        "#{compound}_tyre"
        |> String.to_atom()
        |> F1Bot.ExternalApi.Discord.get_emoji_or_default(":arrows_counterclockwise:")

      msg =
        "#{emoji}  **Pit Stop#{correction}**: `#{driver}` for `#{compound}` tyres (`#{age_str}`)"

      F1Bot.ExternalApi.Discord.post_message(msg)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        e = %{
          scope: "driver:transcript",
          payload: %{
            transcript: %Transcript{
              driver_number: driver_number,
              message: transcript_msg,
              utc_date: utc_date
            }
          }
        },
        state
      ) do
    driver = Common.get_driver_name_by_number(e, driver_number)
    emoji = ":studio_microphone:"

    sec_ago = DateTime.diff(DateTime.utc_now(), utc_date, :second)
    rel_time = "#{sec_ago}s ago"

    msg = "#{emoji} `#{driver}` radio (AI): #{transcript_msg} (`#{rel_time}`)"

    F1Bot.ExternalApi.Discord.post_message({:radio, msg})

    {:noreply, state}
  end

  @impl true
  def handle_info(
        _e = %{
          scope: "session_status:started",
          payload: %{
            gp_name: gp_name,
            session_type: session_type
          }
        },
        state
      ) do
    state =
      if state.session_type == session_type,
        do: state,
        else: %{state | session_type: session_type, segments_done: 0}

    embed = %{
      type: "rich",
      color: 0xE10600,
      title: "🚦 #{gp_name} - #{segment_label(session_type, state.segments_done + 1)}",
      description: "Session just started"
    }

    F1Bot.ExternalApi.Discord.post_message({:embed, embed})

    {:noreply, state}
  end

  @impl true
  def handle_info(
        _e = %{
          scope: "race_control:message",
          payload: %{
            flag: flag,
            message: message,
            source: source
          }
        },
        state
      ) do
    message = strip_trailing_time(message)

    case highlight(flag, message, source) do
      {emoji, label, color} ->
        embed = %{
          type: "rich",
          color: color,
          title: "#{emoji} #{label}",
          description: "#{source_prefix(source)}#{message}"
        }

        F1Bot.ExternalApi.Discord.post_message({:embed, embed})

      nil ->
        emoji = resolve_emoji(:announcement, "📢")
        F1Bot.ExternalApi.Discord.post_message("#{emoji} #{source_prefix(source)}#{message}")
    end

    state = maybe_post_quali_results(state, flag)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.info("Ignored output message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Returns {emoji, label, colour} for messages worth highlighting as an embed,
  # or nil to keep the message as plain text. Covers flags, safety cars and
  # stewards/investigation decisions.
  defp highlight(flag, message, source) do
    cond do
      flag == :green -> {resolve_emoji(:flag_green, "🟢"), "GREEN FLAG", 0x2ECC71}
      flag == :yellow -> {resolve_emoji(:flag_yellow, "🟡"), "YELLOW FLAG", 0xF1C40F}
      flag == :"double yellow" -> {resolve_emoji(:flag_yellow_red, "🟡"), "DOUBLE YELLOW", 0xF1C40F}
      flag == :red -> {resolve_emoji(:flag_red, "🟥"), "RED FLAG", 0xE74C3C}
      flag == :chequered -> {resolve_emoji(:flag_chequered, "🏁"), "CHEQUERED FLAG", 0xFFFFFF}
      flag == :"black and white" -> {resolve_emoji(:flag_black_white, "🏴"), "BLACK AND WHITE FLAG", 0x95A5A6}
      flag == :"black and orange" -> {resolve_emoji(:flag_black_orange, "🟠"), "BLACK AND ORANGE FLAG", 0xE67E22}
      matches?(message, ~r/virtual safety car/iu) -> {resolve_emoji(:vsc, "🟡"), "VIRTUAL SAFETY CAR", 0xF39C12}
      matches?(message, ~r/medical car/iu) -> {"🚑", "MEDICAL CAR", 0xC0392B}
      matches?(message, ~r/safety car/iu) -> {resolve_emoji(:safety_car, "🚗"), "SAFETY CAR", 0xE67E22}
      true -> stewards_highlight(message, source)
    end
  end

  # Stewards / investigation lifecycle: noted -> under investigation ->
  # no further action / penalty.
  defp stewards_highlight(message, source) do
    cond do
      matches?(message, ~r/no further (action|investigation)/iu) ->
        {"✅", "NO FURTHER ACTION", 0x2ECC71}

      matches?(message, ~r/penalty|reprimand/iu) ->
        {"⏱️", "PENALTY", 0xE74C3C}

      matches?(message, ~r/under investigation|will be investigated/iu) ->
        {"🔍", "UNDER INVESTIGATION", 0xF39C12}

      matches?(message, ~r/\bnoted\b/iu) ->
        {"📝", "NOTED", 0xF1C40F}

      source in [:stewards, :stewards_correction] ->
        {"⚖️", "STEWARDS", 0x9B59B6}

      true ->
        nil
    end
  end

  defp matches?(message, regex), do: is_binary(message) and message =~ regex

  # F1 appends its own HH:MM:SS timestamp to race control messages; drop it
  # since Discord already shows the message time.
  defp strip_trailing_time(nil), do: nil

  defp strip_trailing_time(message) do
    message
    |> String.replace(~r/\s*\(?\b\d{1,2}:\d{2}:\d{2}\b\)?/, "")
    |> String.trim()
  end

  defp resolve_emoji(key, fallback), do: F1Bot.ExternalApi.Discord.get_emoji_or_default(key, fallback)

  defp source_prefix(:stewards), do: "FIA Stewards: "
  defp source_prefix(:stewards_correction), do: "FIA Stewards correction: "
  defp source_prefix(_), do: ""

  defp quali?(type), do: type in ["Qualifying", "Sprint Qualifying", "Sprint Shootout"]

  defp segment_label("Qualifying", n), do: "Qualifying - Q#{n}"
  defp segment_label("Sprint Qualifying", n), do: "Sprint Qualifying - SQ#{n}"
  defp segment_label("Sprint Shootout", n), do: "Sprint Shootout - SQ#{n}"
  defp segment_label(type, _n), do: type

  # The chequered flag ends each qualifying segment (immune to red-flag
  # restarts, which never produce a chequered). Post that segment's leaderboard
  # and advance the counter.
  defp maybe_post_quali_results(state, :chequered) do
    if quali?(state.session_type) do
      segment = state.segments_done + 1

      case F1Bot.Output.QualifyingResults.embed(segment) do
        nil -> :ok
        embed -> F1Bot.ExternalApi.Discord.post_message({:embed, embed})
      end

      %{state | segments_done: segment}
    else
      state
    end
  end

  defp maybe_post_quali_results(state, _flag), do: state

  defp server_via() do
    __MODULE__
  end
end
