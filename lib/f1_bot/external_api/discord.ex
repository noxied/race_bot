defmodule F1Bot.ExternalApi.Discord do
  @moduledoc ""
  @callback post_message(String.t() | tuple()) :: :ok | {:error, any()}

  def post_message(message_or_tuple) do
    impl = F1Bot.get_env(:discord_api_module, F1Bot.ExternalApi.Discord.Console)
    impl.post_message(message_or_tuple)
  end

  def get_emoji_or_default(emoji, default) do
    case get_emoji_with_env_override(emoji) do
      nil -> default
      val -> val
    end
  end

  def get_emoji_with_env_override(emoji) do
    emoji_upcase = emoji |> to_string() |> String.upcase()
    env_var = "FLUXER_EMOJI_" <> emoji_upcase

    case System.get_env(env_var) do
      nil -> default_emoji(emoji)
      val -> val
    end
  end

  # Custom emojis uploaded to the Fluxer instance. Override any of these with
  # FLUXER_EMOJI_<KEY>; anything not listed falls back to the caller's unicode.
  def default_emoji(:soft_tyre), do: "<:soft:1552904040575139844>"
  def default_emoji(:medium_tyre), do: "<:medium:1552904040575139843>"
  def default_emoji(:hard_tyre), do: "<:hard:1552904040575139841>"
  def default_emoji(:intermediate_tyre), do: "<:inter:1552904040575139842>"
  def default_emoji(:wet_tyre), do: "<:wet:1552904040575139845>"
  def default_emoji(:fastest_lap), do: "<:fastestlap:1552904040575139840>"
  def default_emoji(:flag_green), do: "<:green:1552904040575139849>"
  def default_emoji(:flag_yellow), do: "<:yellow:1552904040575139850>"
  def default_emoji(:flag_yellow_red), do: "<:yellowred:1552904040575139853>"
  def default_emoji(:flag_red), do: "<:red:1552904040575139846>"
  def default_emoji(:flag_blue), do: "<:blue:1552904040575139851>"
  def default_emoji(:flag_black_white), do: "<:blackwhite:1552904040575139852>"
  def default_emoji(:flag_black_orange), do: "<:blackorange:1552904040575139848>"
  def default_emoji(:vsc), do: "<:vsc:1552904040575139847>"
  def default_emoji(:safety_car), do: "<a:safetycar:1552904040575139854>"
  def default_emoji(_), do: nil
end
