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
  # Post an embed to the message channels while pinging a single role, restricting
  # mentions to that role only (never @everyone).
  def post_message({:embed_ping, role_id, embed}) do
    channel_ids = F1Bot.get_env(:fluxer_channel_ids_messages, [])
    role = to_string(role_id)

    body = %{
      content: "<@&#{role}>",
      embeds: [embed],
      allowed_mentions: %{parse: [], roles: [role]}
    }

    Logger.info(
      "[FLUXER] [embed+ping @#{role}] #{embed[:title]} (to channels: #{inspect(channel_ids)})"
    )

    for channel_id <- channel_ids do
      case post_to_channel(channel_id, body) do
        :ok -> :ok
        {:error, err} -> Logger.error("Failed to post Fluxer message to #{channel_id}: #{inspect(err)}")
      end
    end

    :ok
  end

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

      Finch.build(:post, url, headers, Jason.encode!(body))
      |> request_with_retry(15_000)
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

      Finch.build(:post, url, headers, body)
      |> request_with_retry(30_000)
    end
  end

  # Sends a built request, retrying transient failures so a dropped connection
  # ("terminated") or a 5xx (common when the instance is overloaded or under a
  # DDoS) does not silently drop a live message. Retries network errors, 429 and
  # 5xx with backoff; 4xx (other than 429) fail fast. A 2xx returns `:ok`.
  # Note: a POST cut after the server accepted it may be re-sent, so a rare
  # duplicate is possible, which is preferred over losing a race-control post.
  @max_send_attempts 4

  defp request_with_retry(req, timeout, attempt \\ 1) do
    case Finch.request(req, @finch, receive_timeout: timeout) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status} = resp} when status == 429 or status >= 500 ->
        if attempt < @max_send_attempts do
          Logger.warning(
            "[FLUXER] HTTP #{status}, retrying (#{attempt}/#{@max_send_attempts - 1})"
          )

          Process.sleep(send_backoff(resp, attempt))
          request_with_retry(req, timeout, attempt + 1)
        else
          {:error, {:http_error, status, resp.body}}
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        if attempt < @max_send_attempts do
          Logger.warning(
            "[FLUXER] request failed (#{inspect(reason)}), retrying (#{attempt}/#{@max_send_attempts - 1})"
          )

          Process.sleep(backoff_ms(attempt))
          request_with_retry(req, timeout, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  # For 429, honour Retry-After / x-ratelimit-reset-after; otherwise back off.
  defp send_backoff(%{status: 429, headers: headers}, attempt) do
    retry_after_ms(headers) || backoff_ms(attempt)
  end

  defp send_backoff(_resp, attempt), do: backoff_ms(attempt)

  defp backoff_ms(attempt), do: min(5_000, 500 * Integer.pow(2, attempt - 1))

  defp retry_after_ms(headers) do
    value =
      header_value(headers, "retry-after") || header_value(headers, "x-ratelimit-reset-after")

    with v when is_binary(v) <- value,
         {secs, _} <- Float.parse(v) do
      trunc(secs * 1000) |> max(0) |> min(10_000)
    else
      _ -> nil
    end
  end

  defp header_value(headers, key) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == key, do: v end)
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
