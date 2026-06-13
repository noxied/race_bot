defmodule F1Bot.ExternalApi.Discord.Commands.Help do
  @moduledoc """
  Slash command `/help` - lists the available commands and how to use them.
  """
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common}

  @color 0xE10600

  # {command, i18n description key | literal string}
  @commands [
    {"/nextrace", :nextrace_cmd_desc},
    {"/calendar", :calendar_cmd_desc},
    {"/weather", :weather_cmd_desc},
    {"/drivers", :drivers_cmd_desc},
    {"/teams", :teams_cmd_desc},
    {"/ping", :ping_cmd_desc},
    {"/help", :help_cmd_desc},
    {"/f1summary", "Driver's fastest lap, top speed and stint info (current session)"},
    {"/f1graph", "Graph for the current F1 session"}
  ]

  def handle_interaction(interaction = %Interaction{}) do
    flags = Common.response_flags(interaction)
    locale = Common.locale(interaction)

    lines =
      Enum.map_join(@commands, "\n", fn {name, desc} ->
        "**#{name}** - #{describe(desc, locale)}"
      end)

    embed = %{
      type: "rich",
      color: @color,
      title: I18n.t(:help_title, locale),
      description: lines <> "\n\n" <> I18n.t(:help_public_note, locale)
    }

    Response.make_embed_message(flags, [embed])
    |> Response.send_interaction_response(interaction)
  end

  defp describe(desc, locale) when is_atom(desc), do: I18n.t(desc, locale)
  defp describe(desc, _locale) when is_binary(desc), do: desc
end
