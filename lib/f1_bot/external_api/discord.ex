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

  # No built-in custom emojis on Fluxer: the old Discord emoji IDs would render
  # broken here, so return nil and let each caller's unicode fallback show. Once
  # the emojis are re-uploaded to the Fluxer instance, set FLUXER_EMOJI_<KEY> to
  # the new codes (e.g. FLUXER_EMOJI_SOFT_TYRE) to override per emoji.
  def default_emoji(_), do: nil
end
