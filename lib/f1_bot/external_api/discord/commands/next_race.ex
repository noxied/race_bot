defmodule F1Bot.ExternalApi.Discord.Commands.NextRace do
  @moduledoc """
  Slash command `/nextrace` — shows the next F1 race weekend (data from F1DB).
  """
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.F1DB
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common}

  # F1 red
  @color 0xE10600

  # f1db hosts circuit layouts as SVG. Discord can't render SVG, so we proxy
  # through wsrv.nl which rasterises to PNG on the fly.
  @circuit_svg_base "raw.githubusercontent.com/f1db/f1db/main/src/assets/circuits/white-outline"

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
    flag = Common.flag_emoji(race.country_code)
    title = String.trim("#{flag} #{I18n.t(:nextrace_title, locale)} — #{race.grand_prix}")

    fields =
      [
        %{inline: true, name: I18n.t(:field_round, locale), value: to_string(race.round)},
        %{inline: true, name: I18n.t(:field_circuit, locale), value: circuit_value(race)}
      ]
      |> maybe_add_field(
        I18n.t(:field_countdown, locale),
        Common.relative_timestamp(race.date, race.time),
        true
      )
      |> maybe_add_field(
        I18n.t(:field_sessions, locale),
        format_sessions(race.sessions, locale),
        false
      )

    %{
      type: "rich",
      color: @color,
      title: title,
      description: race.official_name,
      fields: fields
    }
    |> maybe_put_image(circuit_image_url(race.circuit_layout_id))
  end

  defp circuit_image_url(nil), do: nil

  defp circuit_image_url(layout_id),
    do: "https://wsrv.nl/?url=#{@circuit_svg_base}/#{layout_id}.svg&output=png&w=640"

  defp maybe_put_image(embed, nil), do: embed
  defp maybe_put_image(embed, url), do: Map.put(embed, :image, %{url: url})

  defp circuit_value(%{circuit: circuit, place_name: place}) when is_binary(place),
    do: "#{circuit}\n#{place}"

  defp circuit_value(%{circuit: circuit}), do: circuit

  defp maybe_add_field(fields, _name, nil, _inline), do: fields
  defp maybe_add_field(fields, _name, "", _inline), do: fields

  defp maybe_add_field(fields, name, value, inline),
    do: fields ++ [%{inline: inline, name: name, value: value}]

  defp format_sessions(sessions, locale) do
    @session_order
    |> Enum.filter(&Map.has_key?(sessions, &1))
    |> Enum.map_join("\n", fn key ->
      %{date: date, time: time} = sessions[key]
      "**#{I18n.session_label(key, locale)}** — #{Common.session_timestamp(date, time)}"
    end)
  end
end
