defmodule Longbridge.QuoteContext.RealtimeStore do
  @moduledoc """
  In-memory cache of pushed data, keyed by symbol.

  Mirrors the local data store maintained by the upstream
  `longbridge/openapi` Rust and Go SDKs (`SecuritiesData` /
  `Store` in their respective cores). Updated on every push event
  the QuoteContext receives, queried by the `realtime_*` family
  of methods.

  Backed by an ETS table owned by the QuoteContext process so it
  inherits the connection's lifecycle.

  ## Data retained per symbol

    * `quote` — most recent `PushQuote` (one)
    * `depth` — most recent `PushDepth` (one)
    * `brokers` — most recent `PushBrokers` (one)
    * `trades` — recent `PushTrade` entries (capped at 500)
  """

  @max_trades 500
  @table :longbridge_quote_realtime

  ## ── Client API (called by the QuoteContext GenServer) ──

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc false
  def put_quote(server, %Longbridge.Quote.V1.PushQuote{} = push) do
    GenServer.cast(server, {:put_quote, push})
  end

  @doc false
  def put_depth(server, %Longbridge.Quote.V1.PushDepth{} = push) do
    GenServer.cast(server, {:put_depth, push})
  end

  @doc false
  def put_brokers(server, %Longbridge.Quote.V1.PushBrokers{} = push) do
    GenServer.cast(server, {:put_brokers, push})
  end

  @doc false
  def put_trades(server, %Longbridge.Quote.V1.PushTrade{} = push) do
    GenServer.cast(server, {:put_trades, push})
  end

  @doc false
  def get_quote(server, symbols) do
    {:ok, GenServer.call(server, {:get_quote, symbols})}
  end

  @doc false
  def get_depth(server, symbol) do
    case GenServer.call(server, {:get_depth, symbol}) do
      nil -> {:ok, nil}
      push -> {:ok, push}
    end
  end

  @doc false
  def get_brokers(server, symbol) do
    case GenServer.call(server, {:get_brokers, symbol}) do
      nil -> {:ok, nil}
      push -> {:ok, push}
    end
  end

  @doc false
  def get_trades(server, symbol, count) do
    {:ok, GenServer.call(server, {:get_trades, symbol, count})}
  end

  @doc false
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @doc false
  def stop(server) do
    if Process.alive?(server), do: GenServer.stop(server)
    :ok
  end

  ## ── GenServer callbacks ────────────────────────────

  use GenServer

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    # Per-instance table (no :named_table) so multiple QuoteContexts can
    # coexist in one VM. The ref lives in state; the table is owned by this
    # GenServer and dies with it.
    table = :ets.new(@table, [:set, :protected, read_concurrency: true])
    {:ok, %{owner: Keyword.fetch!(opts, :owner), table: table}}
  end

  @impl true
  def handle_call({:get_quote, symbols}, _from, state) do
    quoted =
      Enum.map(symbols, fn sym ->
        case :ets.lookup(state.table, {:quote, sym}) do
          [{_, push}] -> push
          [] -> nil
        end
      end)

    {:reply, quoted, state}
  end

  @impl true
  def handle_call({:get_depth, symbol}, _from, state) do
    reply =
      case :ets.lookup(state.table, {:depth, symbol}) do
        [{_, push}] -> push
        [] -> nil
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_brokers, symbol}, _from, state) do
    reply =
      case :ets.lookup(state.table, {:brokers, symbol}) do
        [{_, push}] -> push
        [] -> nil
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_trades, symbol, count}, _from, state) do
    trades =
      case :ets.lookup(state.table, {:trades, symbol}) do
        [{_, list}] -> Enum.take(list, -min(count, length(list)))
        [] -> []
      end

    {:reply, trades, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:put_quote, %Longbridge.Quote.V1.PushQuote{symbol: sym} = push}, state) do
    :ets.insert(state.table, {{:quote, sym}, push})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:put_depth, %Longbridge.Quote.V1.PushDepth{symbol: sym} = push}, state) do
    :ets.insert(state.table, {{:depth, sym}, push})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:put_brokers, %Longbridge.Quote.V1.PushBrokers{symbol: sym} = push}, state) do
    :ets.insert(state.table, {{:brokers, sym}, push})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:put_trades, %Longbridge.Quote.V1.PushTrade{symbol: sym} = push}, state) do
    key = {:trades, sym}
    new_trades = push.trade
    existing = :ets.lookup(state.table, key)

    list =
      case existing do
        [{_, prev}] -> Enum.take(prev ++ new_trades, -@max_trades)
        [] -> Enum.take(new_trades, -@max_trades)
      end

    :ets.insert(state.table, {key, list})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.table, do: :ets.delete(state.table)
    :ok
  end
end
