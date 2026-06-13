defmodule F1Bot.SessionPersistence do
  @moduledoc """
  Persists a light copy of the live `F1Session` state to disk so the bot keeps
  its memory across restarts.

  On boot it restores from the disk snapshot; if none exists (or it cannot be
  read) it falls back to reloading the last session from the F1 archive over the
  network. The snapshot is rewritten periodically and on graceful shutdown.

  Disabled when no snapshot path is configured (e.g. dev/test/demo), in which
  case it is an inert no-op.
  """
  use GenServer
  require Logger

  alias F1Bot.F1Session

  @save_interval_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Forces an immediate save of the current session to disk."
  def save_now, do: GenServer.call(__MODULE__, :save)

  @impl true
  def init(_) do
    # Trap exits so `terminate/2` runs on graceful shutdown and saves a final snapshot.
    Process.flag(:trap_exit, true)
    send(self(), :restore)
    :timer.send_interval(@save_interval_ms, :save)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:restore, state) do
    restore()
    {:noreply, state}
  end

  @impl true
  def handle_info(:save, state) do
    save()
    {:noreply, state}
  end

  @impl true
  def handle_call(:save, _from, state) do
    {:reply, save(), state}
  end

  @impl true
  def terminate(_reason, _state) do
    save()
    :ok
  end

  # ---- restore -----------------------------------------------------------

  defp restore do
    case path() do
      nil ->
        Logger.info("Session persistence disabled (no snapshot path configured)")

      file ->
        case load_snapshot(file) do
          {:ok, session} ->
            F1Bot.F1Session.Server.replace_session(session)
            Logger.info("Restored session state from disk snapshot: #{file}")

          :empty ->
            Logger.info("No disk snapshot found, falling back to network reload")
            network_reload()

          {:error, reason} ->
            Logger.warning(
              "Failed to read disk snapshot (#{inspect(reason)}), falling back to network reload"
            )

            network_reload()
        end
    end
  end

  defp load_snapshot(file) do
    case File.read(file) do
      {:ok, bin} ->
        try do
          case :erlang.binary_to_term(bin, [:safe]) do
            %F1Session{} = session -> {:ok, normalize(session)}
            _ -> {:error, :unexpected_term}
          end
        rescue
          e -> {:error, e}
        end

      {:error, :enoent} ->
        :empty

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fill in any struct fields added since the snapshot was written (and drop any
  # that were removed), so restoring an older snapshot can never produce a struct
  # missing newer keys.
  defp normalize(%F1Session{} = session) do
    struct(F1Session.new(), Map.from_struct(session))
  end

  # Force the reload so it works even on a race weekend, when F1's streaming
  # status reads "not offline" between sessions. Forcing only bypasses that
  # check; it still requires a completed session archive to exist, so it never
  # overwrites a session that is genuinely in progress.
  defp network_reload do
    case F1Bot.reload_session(true, true) do
      {:error, reason} -> Logger.info("Network session reload skipped: #{inspect(reason)}")
      _ -> :ok
    end
  end

  # ---- save --------------------------------------------------------------

  defp save do
    with file when is_binary(file) <- path(),
         %F1Session{} = session <- F1Bot.session_copy(true),
         true <- meaningful?(session) do
      write_atomic(file, :erlang.term_to_binary(session, compressed: 6))
    else
      _ -> :skip
    end
  end

  defp write_atomic(file, bin) do
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, bin),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to write session snapshot: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Avoid clobbering a good snapshot with an empty session (e.g. between sessions
  # before any data has arrived).
  defp meaningful?(%F1Session{} = s) do
    s.session_info.type != nil or map_size(s.live_timing) > 0
  end

  defp path, do: F1Bot.get_env(:session_snapshot_path)
end
