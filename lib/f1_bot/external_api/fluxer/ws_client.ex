defmodule F1Bot.ExternalApi.Fluxer.WSClient do
  @moduledoc """
  Thin Fresh websocket client for the Fluxer gateway. Forwards connection and
  message events to `F1Bot.ExternalApi.Fluxer.Gateway`.
  """
  use Fresh, restart: :temporary
  require Logger

  alias F1Bot.ExternalApi.Fluxer.Gateway

  @impl Fresh
  def handle_connect(_status, _headers, state) do
    Gateway.ws_handle_connected()
    {:ok, state}
  end

  @impl Fresh
  def handle_in(message, state) do
    Gateway.ws_handle_message(message)
    {:ok, state}
  end

  @impl Fresh
  def handle_error(error, _state) do
    Logger.error("Fluxer gateway connection error: #{inspect(error)}")
    {:close, {:error, error}}
  end

  @impl Fresh
  def handle_disconnect(code, reason, _state) do
    Logger.error("Fluxer gateway disconnected: #{inspect({code, reason})}")
    {:close, {:error, reason}}
  end

  def send(message) do
    Fresh.send(__MODULE__, message)
  end

  def name, do: {:local, __MODULE__}
end
