defmodule F1Bot.ExternalApi.Fluxer do
  @moduledoc """
  Fluxer REST output and shared connection helpers (https://docs.fluxer.app).

  `post_message/1` implements the same contract as the Discord output, so it is a
  drop-in selected through the `:discord_api_module` config. `post_to_channel/2`,
  `bot_token/0` and `gateway_url/0` are shared with the gateway client used for
  prefix commands.

  Auth is `Authorization: Bot <app_id>.<secret>`. The REST base is
  `<FLUXER_ORIGIN>/api` (the instance discovery `endpoints.api_public`, overridable
  with `FLUXER_API_BASE`); messages go to `<base>/v1/channels/{id}/messages`.
  Fluxer embeds are Discord-shaped, so the embed maps built elsewhere post as-is.
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
      case post_to_channel(channel_id, body) do
        :ok ->
          :ok

        {:error, err} ->
          Logger.error("Failed to post Fluxer message to #{channel_id}: #{inspect(err)}")
      end
    end

    :ok
  end

  @doc """
  Posts a message body (`%{content: ...}` or `%{embeds: [...]}`) to a channel via
  REST. Shared by the live output and by command replies.
  """
  def post_to_channel(channel_id, body) do
    with {:ok, base} <- api_base(),
         {:ok, token} <- bot_token() do
      url = "#{base}/v1/channels/#{channel_id}/messages"

      headers = [
        {"authorization", "Bot #{token}"},
        {"content-type", "application/json"}
      ]

      case Finch.build(:post, url, headers, Jason.encode!(body))
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

  @doc """
  Posts a message with an audio file attached (multipart), used for team radio
  clips. `content` is the caption, `binary` the mp3 bytes.
  """
  def post_audio_clip(channel_id, content, filename, binary) do
    with {:ok, base} <- api_base(),
         {:ok, token} <- bot_token() do
      url = "#{base}/v1/channels/#{channel_id}/messages"
      boundary = "f1bot" <> Integer.to_string(System.unique_integer([:positive]))
      payload_json = Jason.encode!(%{content: content, attachments: [%{id: 0, filename: filename}]})

      headers = [
        {"authorization", "Bot #{token}"},
        {"content-type", "multipart/form-data; boundary=#{boundary}"}
      ]

      body = multipart_body(boundary, payload_json, filename, binary)

      case Finch.build(:post, url, headers, body)
           |> Finch.request(@finch, receive_timeout: 30_000) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http_error, status, resp_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp multipart_body(boundary, payload_json, filename, binary) do
    crlf = "\r\n"

    IO.iodata_to_binary([
      "--",
      boundary,
      crlf,
      "content-disposition: form-data; name=\"payload_json\"",
      crlf,
      "content-type: application/json",
      crlf,
      crlf,
      payload_json,
      crlf,
      "--",
      boundary,
      crlf,
      "content-disposition: form-data; name=\"files[0]\"; filename=\"",
      filename,
      "\"",
      crlf,
      "content-type: audio/mpeg",
      crlf,
      crlf,
      binary,
      crlf,
      "--",
      boundary,
      "--",
      crlf
    ])
  end

  @doc "The bot token, or `{:error, :no_fluxer_bot_token}`."
  def bot_token do
    case F1Bot.get_env(:fluxer_bot_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :no_fluxer_bot_token}
    end
  end

  @doc """
  REST base: `FLUXER_API_BASE` if set, else `<FLUXER_ORIGIN>/api`. A trailing
  `/v1` is stripped so the base works whether or not it already includes the API
  version (the message path always appends `/v1/channels/...`). Self-hosted uses a
  single origin (`.../api`); the official instance uses `https://api.fluxer.app`.
  """
  def api_base do
    cond do
      base = present(F1Bot.get_env(:fluxer_api_base)) ->
        {:ok, base |> String.trim_trailing("/") |> String.replace_suffix("/v1", "")}

      origin = present(F1Bot.get_env(:fluxer_origin)) ->
        {:ok, String.trim_trailing(origin, "/") <> "/api"}

      true ->
        {:error, :no_fluxer_origin}
    end
  end

  @doc "Websocket gateway URL: `FLUXER_GATEWAY` if set, else derived from origin."
  def gateway_url do
    cond do
      gw = present(F1Bot.get_env(:fluxer_gateway)) ->
        {:ok, String.trim_trailing(gw, "/")}

      origin = present(F1Bot.get_env(:fluxer_origin)) ->
        ws =
          origin
          |> String.trim_trailing("/")
          |> String.replace_prefix("https://", "wss://")
          |> String.replace_prefix("http://", "ws://")

        {:ok, ws <> "/gateway"}

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
