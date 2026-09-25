defmodule F1Bot.ExternalApi.Fluxer do
  @moduledoc """
  Posts messages and rich embeds to Fluxer channels over the REST API. Implements
  the same `post_message/1` contract as the Discord output, so it is a drop-in
  replacement selected through the `:discord_api_module` config.

  Auth is `Authorization: Bot <app_id>.<secret>` (the bot token). The REST base is
  `<FLUXER_ORIGIN>/api` (matching the instance discovery document's
  `endpoints.api_public`, overridable with `FLUXER_API_BASE`); messages are sent to
  `<base>/v1/channels/{id}/messages`. Fluxer embeds are Discord-shaped, so the
  embed maps built elsewhere are posted as-is.
  """
  require Logger
  @behaviour F1Bot.ExternalApi.Discord

  @finch F1Bot.Finch

  @impl F1Bot.ExternalApi.Discord
  def post_message(message_or_tuple) do
    {type, payload} =
      case message_or_tuple do
        {:embed, embed} -> {:default, {:embed, embed}}
        {:embed, t, embed} -> {t, {:embed, embed}}
        message when is_binary(message) -> {:default, message}
        {t, message} -> {t, message}
      end

    channel_ids =
      case type do
        :radio -> F1Bot.get_env(:fluxer_channel_ids_radios, [])
        _ -> F1Bot.get_env(:fluxer_channel_ids_messages, [])
      end

    body =
      case payload do
        {:embed, embed} -> %{embeds: [embed]}
        content -> %{content: content}
      end

    Logger.info("[FLUXER] #{describe(payload)} (to channels: #{inspect(channel_ids)})")

    for channel_id <- channel_ids do
      case send_message(channel_id, body) do
        :ok ->
          :ok

        {:error, err} ->
          Logger.error("Failed to post Fluxer message to #{channel_id}: #{inspect(err)}")
      end
    end

    :ok
  end

  defp send_message(channel_id, body) do
    with {:ok, base} <- api_base(),
         {:ok, token} <- token() do
      url = "#{base}/v1/channels/#{channel_id}/messages"

      headers = [
        {"authorization", "Bot #{token}"},
        {"content-type", "application/json"}
      ]

      json = Jason.encode!(body)

      case Finch.build(:post, url, headers, json)
           |> Finch.request(@finch, receive_timeout: 15_000) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http_error, status, resp_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp token do
    case F1Bot.get_env(:fluxer_bot_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :no_fluxer_bot_token}
    end
  end

  # REST base: FLUXER_API_BASE if set, else <FLUXER_ORIGIN>/api.
  defp api_base do
    cond do
      base = present(F1Bot.get_env(:fluxer_api_base)) ->
        {:ok, String.trim_trailing(base, "/")}

      origin = present(F1Bot.get_env(:fluxer_origin)) ->
        {:ok, String.trim_trailing(origin, "/") <> "/api"}

      true ->
        {:error, :no_fluxer_origin}
    end
  end

  defp present(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end

  defp present(_), do: nil

  defp describe({:embed, embed}), do: "[embed] #{embed[:title]}"
  defp describe(content), do: content
end
