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

    state = %{}

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
    embed = %{
      type: "rich",
      color: 0xE10600,
      title: "🚦 #{gp_name} - #{session_type}",
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
    case highlight_spec(flag, message) do
      {emoji_key, fallback, label, color} ->
        emoji = F1Bot.ExternalApi.Discord.get_emoji_or_default(emoji_key, fallback)

        embed = %{
          type: "rich",
          color: color,
          title: "#{emoji} #{label}",
          description: "#{source_prefix(source)}#{message}"
        }

        F1Bot.ExternalApi.Discord.post_message({:embed, embed})

      nil ->
        emoji = F1Bot.ExternalApi.Discord.get_emoji_or_default(:announcement, "📢")
        F1Bot.ExternalApi.Discord.post_message("#{emoji} #{source_prefix(source)}#{message}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.info("Ignored output message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Highlight spec {emoji_key, fallback_emoji, label, colour} for flags and
  # safety cars; nil means the message stays as plain text.
  defp highlight_spec(:green, _msg), do: {:flag_green, "🟢", "GREEN FLAG", 0x2ECC71}
  defp highlight_spec(:yellow, _msg), do: {:flag_yellow, "🟡", "YELLOW FLAG", 0xF1C40F}

  defp highlight_spec(:"double yellow", _msg),
    do: {:flag_yellow_red, "🟡", "DOUBLE YELLOW", 0xF1C40F}

  defp highlight_spec(:red, _msg), do: {:flag_red, "🟥", "RED FLAG", 0xE74C3C}
  defp highlight_spec(:chequered, _msg), do: {:flag_chequered, "🏁", "CHEQUERED FLAG", 0xFFFFFF}

  defp highlight_spec(:"black and white", _msg),
    do: {:flag_black_white, "🏴", "BLACK AND WHITE FLAG", 0x95A5A6}

  defp highlight_spec(:"black and orange", _msg),
    do: {:flag_black_orange, "🟠", "BLACK AND ORANGE FLAG", 0xE67E22}

  # Safety car / VSC arrive without a Flag field; detect them from the message.
  defp highlight_spec(_flag, msg) when is_binary(msg) do
    cond do
      msg =~ ~r/virtual safety car/iu -> {:vsc, "🟡", "VIRTUAL SAFETY CAR", 0xF39C12}
      msg =~ ~r/safety car/iu -> {:safety_car, "🚗", "SAFETY CAR", 0xE67E22}
      true -> nil
    end
  end

  defp highlight_spec(_flag, _msg), do: nil

  defp source_prefix(:stewards), do: "FIA Stewards: "
  defp source_prefix(:stewards_correction), do: "FIA Stewards correction: "
  defp source_prefix(_), do: ""

  defp server_via() do
    __MODULE__
  end
end
