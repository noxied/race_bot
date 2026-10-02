defmodule F1Bot.ExternalApi.Fluxer.Gateway do
  @moduledoc """
  Fluxer gateway client for prefix (`!`) commands. Connects over a websocket
  (`?v=1&encoding=json`, no compression), performs the handshake and forwards
  `MESSAGE_CREATE` events to `F1Bot.ExternalApi.Fluxer.Commands`.

  Protocol (https://docs.fluxer.app/gateway): receive Hello (op 10) with
  `heartbeat_interval`, then send Identify (op 2) and a periodic Heartbeat
  (op 1, `d` = last dispatch sequence). Dispatches arrive as op 0 with `t`/`s`/`d`.

  The websocket process is monitored (not linked): when it drops, or on a
  Reconnect (op 7) / Invalid Session (op 9), this process stays alive and
  reconnects with exponential backoff (reset once READY arrives). This keeps a
  flapping connection, e.g. during a DDoS, from hammering the instance or
  crash-looping the supervisor.
  """
  use GenServer
  require Logger

  alias F1Bot.ExternalApi.Fluxer
  alias F1Bot.ExternalApi.Fluxer.{WSClient, Commands}

  @supervisor F1Bot.DynamicSupervisor

  @reconnect_base_ms 1_000
  @reconnect_max_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def ws_handle_connected, do: GenServer.cast(__MODULE__, :ws_connected)
  def ws_handle_message(message), do: GenServer.cast(__MODULE__, {:ws_message, message})

  @impl true
  def init(_opts) do
    state = %{
      ws_pid: nil,
      ws_ref: nil,
      hb_tref: nil,
      last_seq: nil,
      session_id: nil,
      reconnects: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, connect(state)}
  end

  defp connect(state) do
    state = cancel_heartbeat(state)

    with {:ok, gateway} <- Fluxer.gateway_url(),
         {:ok, _token} <- Fluxer.bot_token() do
      uri = "#{ensure_path(gateway)}?v=1&encoding=json"
      Logger.info("Fluxer Gateway: connecting to #{uri}")

      child = {WSClient, [uri: uri, state: %{}, opts: [name: WSClient.name()]]}

      case DynamicSupervisor.start_child(@supervisor, child) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          %{state | ws_pid: pid, ws_ref: ref}

        {:error, {:already_started, pid}} ->
          # A stale client is still registered; stop it and retry shortly.
          DynamicSupervisor.terminate_child(@supervisor, pid)
          schedule_reconnect(state)

        {:error, reason} ->
          Logger.error("Fluxer Gateway: start failed (#{inspect(reason)})")
          schedule_reconnect(state)
      end
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

  # The websocket process went down: reconnect with backoff.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ws_ref: ref} = state) do
    Logger.warning("Fluxer Gateway: websocket down (#{inspect(reason)}); reconnecting")
    state = %{state | ws_pid: nil, ws_ref: nil} |> cancel_heartbeat()
    {:noreply, schedule_reconnect(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # Scheduled reconnect (either a backoff tick or a server-requested reconnect).
  def handle_info(:connect, state) do
    {:noreply, connect(state)}
  end

  def handle_info(:reconnect, state) do
    {:noreply, state |> stop_ws() |> connect()}
  end

  # ---- gateway opcodes ----------------------------------------------------

  # Hello: start heartbeats and identify.
  defp dispatch(%{"op" => 10, "d" => %{"heartbeat_interval" => interval}}, state) do
    Logger.info("Fluxer Gateway: Hello (heartbeat #{interval}ms)")
    state = cancel_heartbeat(state)
    {:ok, tref} = :timer.send_interval(interval, :heartbeat)
    identify()
    %{state | hb_tref: tref}
  end

  # Heartbeat ACK
  defp dispatch(%{"op" => 11}, state), do: state

  # Reconnect / Invalid Session: drop the socket and reconnect.
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
    %{state | session_id: data["session_id"], reconnects: 0}
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

  # Stop the current websocket process (demonitoring it so its :DOWN does not
  # trigger a second reconnect) and clear the heartbeat.
  defp stop_ws(state) do
    if state.ws_ref, do: Process.demonitor(state.ws_ref, [:flush])

    if state.ws_pid && Process.alive?(state.ws_pid) do
      DynamicSupervisor.terminate_child(@supervisor, state.ws_pid)
    end

    %{state | ws_pid: nil, ws_ref: nil} |> cancel_heartbeat()
  end

  defp schedule_reconnect(state) do
    delay = min(@reconnect_max_ms, @reconnect_base_ms * Integer.pow(2, min(state.reconnects, 5)))
    Logger.info("Fluxer Gateway: reconnecting in #{delay}ms")
    Process.send_after(self(), :connect, delay)
    %{state | reconnects: state.reconnects + 1}
  end

  defp cancel_heartbeat(%{hb_tref: nil} = state), do: state

  defp cancel_heartbeat(%{hb_tref: tref} = state) do
    :timer.cancel(tref)
    %{state | hb_tref: nil}
  end

  # Ensure the gateway URL has a path before the query string. Single-origin
  # instances give a path (".../gateway"); a dedicated gateway host may not
  # ("wss://gateway.fluxer.app"), and "host?query" can confuse the WS client.
  defp ensure_path(url) do
    if url =~ ~r{://[^/]+/}, do: url, else: url <> "/"
  end
end
