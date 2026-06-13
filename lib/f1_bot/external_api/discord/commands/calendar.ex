defmodule F1Bot.ExternalApi.Discord.Commands.Calendar do
  @moduledoc """
  Slash command `/calendar` - shows the current F1 season calendar (data from F1DB).
  """
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.F1DB
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common}

  @color 0xE10600

  def handle_interaction(interaction = %Interaction{}) do
    flags = Common.response_flags(interaction)
    locale = Common.locale(interaction)

    response =
      case F1DB.current_season_races() do
        {:ok, %{year: year, races: races}} when races != [] ->
          Response.make_embed_message(flags, [build_embed(year, races, locale)])

        {:ok, _empty} ->
          Response.make_message(flags, I18n.t(:none_found, locale))

        {:error, :not_loaded} ->
          Response.make_message(flags, I18n.t(:data_not_ready, locale))
      end

    Response.send_interaction_response(response, interaction)
  end

  defp build_embed(year, races, locale) do
    lines =
      Enum.map_join(races, "\n", fn r ->
        round = String.pad_leading(to_string(r.round), 2)
        flag = Common.flag_emoji(r.country_code)
        "`#{round}` #{flag} **#{r.grand_prix}** - #{Common.date_timestamp(r.date)}"
      end)

    %{
      type: "rich",
      color: @color,
      title: I18n.t(:calendar_title, locale, %{year: year}),
      description: lines
    }
  end
end
