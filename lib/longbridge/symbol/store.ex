defmodule Longbridge.Symbol.Store do
  @moduledoc """
  Long-lived owner of the `Symbol.Directory` and `Symbol.Cache` ETS tables.

  Both tables are read-mostly and were previously created lazily by
  whichever process first called `ensure_loaded/0`. That made the table
  owner a short-lived caller (e.g. a `Task`), so when the caller exited
  the table died and concurrent readers crashed with
  `:ets.member/:undefined` (`ArgumentError`). This GenServer owns the
  tables so they survive arbitrary caller death.

  It is started under `Longbridge.Application` in production. In contexts
  where the app is not started (tests, `iex`), it is started lazily and
  *unlinked* on first use so it outlives the process that triggered it.

  The tables stay `:public, read_concurrency: true`, so readers never go
  through this GenServer — only (re)creation does. `ensure_directory/0`
  / `ensure_cache/0` fast-path on `:ets.info/1` and only call the owner
  when the table is missing (e.g. after a test `:ets.delete/1`).

  The actual table creation + loading stays in `Symbol.Directory` /
  `Symbol.Cache` (`create_and_load!/0` / `create_and_load/0`); the owner
  invokes them so the table is registered to the owner. Directory load
  failures (missing embedded CSV) are returned to the caller and
  re-raised there, preserving the original `raise` contract.
  """

  use GenServer

  @dir_table :longbridge_symbol_directory
  @cache_table :longbridge_symbol_cache

  # ── Public API ──────────────────────────────────────────

  @doc false
  @spec ensure_directory() :: :ok
  def ensure_directory do
    if table?(@dir_table) do
      :ok
    else
      case call(:ensure_directory) do
        :ok -> :ok
        {:error, exception, stack} -> reraise(exception, stack)
      end
    end
  end

  @doc false
  @spec ensure_cache() :: :ok
  def ensure_cache do
    if table?(@cache_table), do: :ok, else: call(:ensure_cache)
  end

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── GenServer callbacks ─────────────────────────────────

  @impl true
  def init(_opts) do
    # Tables are created on first use, not here, so that a missing-CSV
    # load failure surfaces from the caller (via handle_call's rescue)
    # rather than crashing a supervised child at boot.
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:ensure_directory, _from, state) do
    reply =
      if table?(@dir_table) do
        :ok
      else
        try do
          Longbridge.Symbol.Directory.create_and_load!()
          :ok
        rescue
          e -> {:error, e, __STACKTRACE__}
        end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:ensure_cache, _from, state) do
    reply =
      if table?(@cache_table) do
        :ok
      else
        Longbridge.Symbol.Cache.create_and_load()
        :ok
      end

    {:reply, reply, state}
  end

  # ── Helpers ─────────────────────────────────────────────

  defp call(request) do
    ensure_started()
    GenServer.call(__MODULE__, request, :infinity)
  end

  # Starts the owner if it isn't running. Unlinked so caller death does
  # not take the owner (and its tables) down. A concurrent start that
  # loses the name race just reuses the winner via `:already_started`.
  defp ensure_started do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> exit(reason)
    end
  end

  defp table?(name), do: :ets.info(name) != :undefined
end
