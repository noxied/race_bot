defmodule F1Bot.ExternalApi.Discord.Commands.NextRace do
  @moduledoc """
  Slash command `/nextrace` — shows the next F1 race weekend (data from F1DB).
  """
  require Logger
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.F1DB
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common}

  # F1 red
  @color 0xE10600

  @session_order [
    :free_practice_1,
    :free_practice_2,
    :free_practice_3,
    :sprint_qualifying,
    :sprint,
    :qualifying,
    :race
  ]

  def handle_interaction(interaction = %Interaction{}) do
    flags = Common.response_flags(interaction)
    locale = Common.locale(interaction)

    response =
      case F1DB.next_race() do
        {:ok, race} ->
          Response.make_embed_message(flags, [build_embed(race, locale)])

        {:error, :no_upcoming_race} ->
          Response.make_message(flags, I18n.t(:nextrace_none, locale))

        {:error, :not_loaded} ->
          Response.make_message(flags, I18n.t(:data_not_ready, locale))
      end

    Response.send_interaction_response(response, interaction)
  end

  defp build_embed(race, locale) do
    fields =
      [
        %{inline: true, name: I18n.t(:field_round, locale), value: to_string(race.round)},
        %{inline: true, name: I18n.t(:field_circuit, locale), value: race.circuit}
      ]
      |> maybe_add_field(I18n.t(:field_countdown, locale), format_countdown(race, locale), true)
      |> maybe_add_field(I18n.t(:field_sessions, locale), format_sessions(race.sessions, locale), false)

    %{
      type: "rich",
      color: @color,
      title: "#{I18n.t(:nextrace_title, locale)} — #{race.grand_prix}",
      description: race.official_name,
      fields: fields
    }
  end

  defp maybe_add_field(fields, _name, nil, _inline), do: fields
  defp maybe_add_field(fields, _name, "", _inline), do: fields

  defp maybe_add_field(fields, name, value, inline),
    do: fields ++ [%{inline: inline, name: name, value: value}]

  defp format_sessions(sessions, locale) do
    @session_order
    |> Enum.filter(&Map.has_key?(sessions, &1))
    |> Enum.map_join("\n", fn key ->
      %{date: date, time: time} = sessions[key]
      "**#{I18n.session_label(key, locale)}** — #{date}#{format_time_suffix(time)}"
    end)
  end

  defp format_time_suffix(nil), do: ""
  defp format_time_suffix(time) when is_binary(time), do: " #{String.slice(time, 0, 5)}"
  defp format_time_suffix(_), do: ""

  defp format_countdown(race, locale) do
    with {:ok, date} <- Date.from_iso8601(race.date),
         start_dt <- DateTime.new!(date, race_time(race.time), "Etc/UTC"),
         diff when diff > 0 <- DateTime.diff(start_dt, DateTime.utc_now(), :second) do
      days = div(diff, 86_400)
      hours = div(rem(diff, 86_400), 3_600)
      minutes = div(rem(diff, 3_600), 60)
      I18n.t(:countdown_value, locale, %{days: days, hours: hours, minutes: minutes})
    else
      _ -> nil
    end
  end

  defp race_time(nil), do: ~T[12:00:00]

  defp race_time(str) when is_binary(str) do
    case Time.from_iso8601(str) do
      {:ok, time} -> time
      _ -> ~T[12:00:00]
    end
  end
end
