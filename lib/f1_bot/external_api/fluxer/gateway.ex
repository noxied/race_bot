defmodule F1Bot.ExternalApi.Fluxer.Gateway do
  @moduledoc """
  Fluxer gateway client for prefix (`!`) commands. Connects over a websocket
  (`?v=1&encoding=json`, no compression), performs the handshake and forwards
  `MESSAGE_CREATE` events to `F1Bot.ExternalApi.Fluxer.Commands`.

  Protocol (https://docs.fluxer.app/gateway): receive Hello (op 10) with
  `heartbeat_interval`, then send Identify (op 2) and a periodic Heartbeat
  (op 1, `d` = last dispatch sequence). Dispatches arrive as op 0 with `t`/`s`/`d`.
  On Reconnect (op 7) or Invalid Session (op 9) the process stops and is restarted
  by the supervisor, which reconnects and re-identifies.
  """
  use GenServer
  require Logger

  alias F1Bot.ExternalApi.Fluxer
  alias F1Bot.ExternalApi.Fluxer.{WSClient, Commands}

  @supervisor F1Bot.DynamicSupervisor

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def ws_handle_connected, do: GenServer.cast(__MODULE__, :ws_connected)
  def ws_handle_message(message), do: GenServer.cast(__MODULE__, {:ws_message, message})

  @impl true
  def init(_opts) do
    state = %{ws_pid: nil, heartbeat_interval: nil, last_seq: nil, session_id: nil}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, connect(state)}
  end

  defp connect(state) do
    with {:ok, gateway} <- Fluxer.gateway_url(),
         {:ok, _token} <- Fluxer.bot_token() do
      uri = "#{gateway}?v=1&encoding=json"
      Logger.info("Fluxer Gateway: connecting to #{uri}")

      {:ok, pid} =
        DynamicSupervisor.start_child(
          @supervisor,
          {WSClient, [uri: uri, state: %{}, opts: [name: WSClient.name()]]}
        )

      Process.link(pid)
      %{state | ws_pid: pid}
    else
      err ->
        Logger.error("Fluxer Gateway: not connecting (#{inspect(err)}); commands disabled")
        state
    end
  end

  @impl true
  def handle_cast(:ws_connected, state) do
    Logger.info("Fluxer Gateway: websocket connected, awaiting Hello")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:ws_message, {:text, raw}}, state) do
    state =
      case Jason.decode(raw) do
        {:ok, msg} -> dispatch(msg, state)
        {:error, _} -> state
      end

    {:noreply, state}
  end

  def handle_cast({:ws_message, _other}, state), do: {:noreply, state}

  @impl true
  def handle_info(:heartbeat, state) do
    send_ws(%{op: 1, d: state.last_seq})
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    {:stop, :reconnect, state}
  end

  # ---- gateway opcodes ----------------------------------------------------

  # Hello: start heartbeats and identify.
  defp dispatch(%{"op" => 10, "d" => %{"heartbeat_interval" => interval}}, state) do
    Logger.info("Fluxer Gateway: Hello (heartbeat #{interval}ms)")
    :timer.send_interval(interval, :heartbeat)
    identify()
    %{state | heartbeat_interval: interval}
  end

  # Heartbeat ACK
  defp dispatch(%{"op" => 11}, state), do: state

  # Reconnect / Invalid Session: stop and let the supervisor restart us.
  defp dispatch(%{"op" => op}, state) when op in [7, 9] do
    Logger.warning("Fluxer Gateway: reconnect requested (op #{op})")
    send(self(), :reconnect)
    state
  end

  # Dispatch: track the sequence and handle the event.
  defp dispatch(%{"op" => 0, "t" => type, "s" => seq, "d" => data}, state) do
    handle_event(type, data, %{state | last_seq: seq})
  end

  defp dispatch(_other, state), do: state

  # ---- dispatched events --------------------------------------------------

  defp handle_event("READY", data, state) do
    username = get_in(data, ["user", "username"])
    Logger.info("Fluxer Gateway: READY as #{username}")
    %{state | session_id: data["session_id"]}
  end

  defp handle_event("MESSAGE_CREATE", data, state) do
    Commands.handle_message(data)
    state
  end

  defp handle_event(_type, _data, state), do: state

  # ---- helpers ------------------------------------------------------------

  defp identify do
    case Fluxer.bot_token() do
      {:ok, token} ->
        send_ws(%{
          op: 2,
          d: %{
            token: token,
            properties: %{os: "Linux", browser: "F1Bot", device: "server"}
          }
        })

      _ ->
        :ok
    end
  end

  defp send_ws(message) do
    WSClient.send({:text, Jason.encode!(message)})
  end
end
