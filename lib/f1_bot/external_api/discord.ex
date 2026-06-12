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
    env_var = "DISCORD_EMOJI_" <> emoji_upcase

    case System.get_env(env_var) do
      nil -> default_emoji(emoji)
      val -> val
    end
  end

  def default_emoji(:announcement), do: "<:f1_announcement:918883988867788830>"
  def default_emoji(:quick), do: "<:f1_quick:918883439028109313>"
  def default_emoji(:speedometer), do: "<:f1_speedometer:918882472551395388>"
  def default_emoji(:timer), do: "<:f1_timer:918882914899484672>"
  def default_emoji(:hard_tyre), do: "<:f1_tyre_hard:918870511713415278>"
  def default_emoji(:medium_tyre), do: "<:f1_tyre_medium:918870511772123186>"
  def default_emoji(:soft_tyre), do: "<:f1_tyre_soft:918870511646310440>"
  def default_emoji(:test_tyre), do: "<:f1_tyre_test:918870511801487420>"
  def default_emoji(:wet_tyre), do: "<:f1_tyre_wet:918870511591763998>"
  def default_emoji(:intermediate_tyre), do: "<:f1_tyre_intermediate:918870511625306142>"
  def default_emoji(:flag_yellow), do: "<:f1_flag_yellow:918888979808518174>"
  def default_emoji(:flag_red), do: "<:f1_flag_red:918888944450547803>"
  def default_emoji(:flag_chequered), do: "<:f1_flag_chequered:919209710647935037>"
  # Track status / extra flags (defaults are the deployment server's emojis;
  # override with DISCORD_EMOJI_<KEY>).
  def default_emoji(:flag_green), do: "<:green:1398564440416321556>"
  def default_emoji(:flag_blue), do: "<:blue:1398564423320469554>"
  def default_emoji(:flag_yellow_red), do: "<:yellowred:1398564447601168424>"
  def default_emoji(:flag_black_white), do: "<:blackwhite:1398564421894279228>"
  def default_emoji(:flag_black_orange), do: "<:blackorange:1398564419944058962>"
  def default_emoji(:vsc), do: "<:vsc:1398564444182806639>"
  def default_emoji(:safety_car), do: "<a:SafetyCar:1398564418186510418>"
  def default_emoji(_), do: nil
end
