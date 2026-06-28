defmodule Longbridge.Symbol.Directory do
  @moduledoc """
  Vendored subset of the upstream `counter.rs` directory:
  special counter_ids known at build time (ETFs, US indexes, US warrants).
  New listings resolved at runtime go through `Longbridge.Symbol.Cache`.
  """

  @ets :longbridge_symbol_directory

  @doc """
  Looks up a user symbol against the embedded directory. Returns the
  counter_id (e.g. `"ETF/US/SPY"`) on hit, `nil` otherwise.

  Does **not** apply the default `ST/` fallback — callers should do that
  themselves so the priority order (`ST/`, `IX/`, `ETF/`, `WT/`) matches
  the upstream.
  """
  @spec lookup(String.t(), String.t(), String.t()) :: String.t() | nil
  def lookup(symbol, market, code) do
    ensure_loaded()

    # 1. Leading-dot symbols are always IX/.
    if String.starts_with?(symbol, ".") do
      "IX/#{market}/#{code}"
    else
      prefixes = ["ETF", "IX", "WT"]

      Enum.find_value(prefixes, fn prefix ->
        candidate = "#{prefix}/#{market}/#{code}"

        if :ets.member(@ets, candidate), do: candidate
      end)
    end
  end

  @spec ensure_loaded() :: :ok
  defp ensure_loaded do
    Longbridge.Symbol.Store.ensure_directory()
  end

  @doc false
  # The ETS table name. Exposed so tests can inspect ownership without
  # hardcoding the internal atom.
  @spec table() :: atom()
  def table, do: @ets

  @doc false
  # Creates the directory ETS table and loads the embedded CSVs. The
  # table is registered to the calling process, so this is invoked by
  # `Longbridge.Symbol.Store` (a long-lived GenServer) to keep the table
  # alive across arbitrary caller death. Raises on a missing/unreadable
  # CSV; `Store.ensure_directory/0` re-raises that in the original caller.
  @spec create_and_load!() :: :ok
  def create_and_load! do
    _ = :ets.new(@ets, [:set, :named_table, :public, read_concurrency: true])
    load_file("US-ETF.csv")
    load_file("US-IX.csv")
    load_file("US-WT.csv")
    :ok
  end

  @doc false
  # Drops the directory ETS table so the next lookup reloads the
  # embedded CSVs. Used to force the reload / load-failure paths. Safe
  # to call when the table is already gone.
  @spec drop() :: :ok
  def drop do
    try do
      :ets.delete(@ets)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp load_file(name) do
    base = Application.app_dir(:longbridge, "priv/counter_ids")

    case File.read(Path.join(base, name)) do
      {:ok, content} ->
        Enum.each(String.split(content, "\n", trim: true), fn line ->
          if line != "", do: :ets.insert(@ets, {line})
        end)

      {:error, reason} ->
        raise "longbridge directory #{name} could not be loaded: #{inspect(reason)}"
    end
  end
end
