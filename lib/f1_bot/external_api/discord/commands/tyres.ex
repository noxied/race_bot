defmodule F1Bot.ExternalApi.Discord.Commands.Tyres do
  @moduledoc """
  Slash command `/tyres` - the full tyre set sequence used by each driver in the
  current session, in running order. Rendered in the embed description (which has
  a larger character budget than fields) so the complete compound history can be
  shown with custom emojis. Available while a session is live.
  """
  alias Nostrum.Struct.Interaction
  alias F1Bot.ExternalApi.Discord.I18n
  alias F1Bot.ExternalApi.Discord.Commands.{Response, Common}

  # F1 red
  @color 0xE10600

  def handle_interaction(interaction = %Interaction{}) do
    flags = Common.response_flags(interaction)
    locale = Common.locale(interaction)

    response =
      case F1Bot.live_standings() do
        {:ok, %{standings: [_ | _]} = data} ->
          Response.make_embed_message(flags, [build_embed(data, locale)])

        _ ->
          Response.make_message(flags, I18n.t(:tyres_none, locale))
      end

    Response.send_interaction_response(response, interaction)
  end

  defp build_embed(data, locale) do
    %{
      type: "rich",
      color: @color,
      title: title(data, locale),
      description: Enum.map_join(data.standings, "\n", &line/1),
      footer: %{text: footer_text(data, locale)}
    }
  end

  defp line(e) do
    pos = e.position |> to_string() |> String.pad_leading(2)
    "`P#{pos}` `#{e.abbr}` #{sequence(e)}"
  end

  defp sequence(%{tyres: []}), do: "`-`"

  defp sequence(e) do
    emojis = Enum.map_join(e.tyres, "", &tyre_emoji/1)

    case e.tyre_age do
      age when is_integer(age) -> "#{emojis} `#{age}`"
      _ -> emojis
    end
  end

  defp title(data, locale) do
    base = "🛞 #{I18n.t(:tyres_title, locale)}"

    parts =
      [data.gp_name, data.session_type]
      |> Enum.reject(&(&1 == nil))

    case parts do
      [] -> base
      _ -> base <> " - " <> Enum.join(parts, " · ")
    end
  end

  defp footer_text(%{live: true}, locale), do: I18n.t(:positions_footer_live, locale)
  defp footer_text(_data, locale), do: I18n.t(:positions_footer_stale, locale)

  defp tyre_emoji(nil), do: "⬤"

  defp tyre_emoji(compound) do
    default =
      case compound do
        :soft -> "🔴"
        :medium -> "🟡"
        :hard -> "⚪"
        :intermediate -> "🟢"
        :wet -> "🔵"
        _ -> "⬤"
      end

    F1Bot.ExternalApi.Discord.get_emoji_or_default(:"#{compound}_tyre", default)
  end
end
