defmodule F1Bot.ExternalApi.Discord.Commands.Teams do
  @moduledoc """
  Slash command `/teams` - current constructor (team) championship standings (F1DB).
  """
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.F1DB
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common, Standings}

  @color 0xE10600

  def handle_interaction(interaction = %Interaction{}) do
    flags = Common.response_flags(interaction)
    locale = Common.locale(interaction)

    response =
      with {:ok, year} <- F1DB.current_season(),
           {:ok, %{standings: [_ | _] = standings}} <- F1DB.constructor_standings(year) do
        embed =
          Standings.embed(
            I18n.t(:teams_title, locale, %{year: year}),
            standings,
            & &1.constructor,
            @color
          )

        Response.make_embed_message(flags, [embed])
      else
        {:error, :not_loaded} -> Response.make_message(flags, I18n.t(:data_not_ready, locale))
        _ -> Response.make_message(flags, I18n.t(:none_found, locale))
      end

    Response.send_interaction_response(response, interaction)
  end
end
