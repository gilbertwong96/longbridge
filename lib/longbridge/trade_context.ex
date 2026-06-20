defmodule Longbridge.TradeContext do
  @moduledoc """
  Trade connection context for Longbridge trading APIs.

  Manages a connection to the trade endpoint and provides
  APIs for order submission, portfolio queries, and trade push subscriptions.

  ## Usage

      {:ok, ctx} = Longbridge.TradeContext.start_link(config)

      # Subscribe to order status pushes
      :ok = Longbridge.TradeContext.subscribe(ctx)
  """

  use GenServer
  alias Longbridge.{Config, Connection}
  alias Longbridge.Trade.V1, as: T

  # ── Command codes ────────────────────────────────────────

  @cmd_subscribe 16
  @cmd_unsubscribe 17

  # ── Client API ───────────────────────────────────────────

  @doc "Starts a TradeContext linked to the calling process."
  @spec start_link(Config.t(), keyword()) :: GenServer.on_start()
  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, {config, opts}, opts)
  end

  @doc "Returns the current session info."
  @spec session(pid()) :: {:ok, String.t(), integer()} | {:error, term()}
  def session(pid) do
    GenServer.call(pid, :session)
  end

  @doc """
  Subscribes to trade push data (order status updates, etc.).
  Push data arrives as `{:longbridge, conn_pid, {:push, cmd_code, body}}` messages.
  """
  @spec subscribe(pid()) :: :ok | {:error, term()}
  def subscribe(pid) do
    req = %T.Sub{}

    case request_raw(pid, @cmd_subscribe, req) do
      {:ok, _body, _req_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Unsubscribes from trade push data."
  @spec unsubscribe(pid()) :: :ok | {:error, term()}
  def unsubscribe(pid) do
    req = %T.Unsub{}

    case request_raw(pid, @cmd_unsubscribe, req) do
      {:ok, _body, _req_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────

  @impl true
  def init({config, opts}) do
    conn_opts = [config: config, type: :trade, parent: self()]
    {:ok, conn} = Connection.start_link(conn_opts)

    if name = Keyword.get(opts, :name) do
      Process.register(self(), name)
    end

    schedule_heartbeat(config.heartbeat_interval)

    {:ok, %{conn: conn, config: config}}
  end

  @impl true
  def handle_call(:session, _from, state) do
    reply = Connection.get_session(state.conn)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    send(state.conn, :heartbeat)
    schedule_heartbeat(state.config.heartbeat_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:longbridge, conn, msg}, %{conn: conn} = state) do
    send(self(), {:longbridge_push, msg})
    {:noreply, state}
  end

  # ── Helpers ──────────────────────────────────────────────

  defp request_raw(pid, cmd_code, req_msg) do
    {:ok, iodata, _size} = Protox.encode(req_msg)
    body = IO.iodata_to_binary(iodata)
    GenServer.call(pid, {:request, cmd_code, body, 10_000}, 15_000)
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end
end
