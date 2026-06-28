defmodule Longbridge.Symbol.Cache do
  @moduledoc false
  # Runtime-resolved counter_ids persisted to
  # `$LONGBRIDGE_CACHE_DIR/counter-ids.csv` (default
  # `~/.longbridge/cache/counter-ids.csv`). One counter_id per line,
  # mirroring the format of the embedded directory files in
  # `priv/counter_ids/`.

  @ets :longbridge_symbol_cache

  @cache_path_env "LONGBRIDGE_CACHE_DIR"

  @doc """
  Look up a user symbol against the on-disk cache. Returns the
  counter_id on hit, `nil` otherwise.
  """
  @spec lookup(String.t()) :: String.t() | nil
  def lookup(symbol) do
    ensure_loaded()

    case String.split(symbol, ".") do
      [code, market] ->
        market = String.upcase(market)

        code =
          if market == "HK" and String.match?(code, ~r/^\d+$/) do
            String.replace_leading(code, "0", "")
          else
            code
          end

        Enum.find_value(["ETF", "IX", "WT", "ST"], fn prefix ->
          candidate = "#{prefix}/#{market}/#{code}"

          if :ets.member(@ets, candidate), do: candidate
        end)

      _other ->
        nil
    end
  end

  @doc """
  Add new counter_ids to the in-memory cache and persist them to disk.
  Duplicates are ignored.
  """
  @spec put([String.t()]) :: :ok
  def put(counter_ids) do
    ensure_loaded()

    counter_ids =
      counter_ids
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    added =
      Enum.reduce(counter_ids, 0, fn cid, count ->
        if :ets.insert_new(@ets, {cid}), do: count + 1, else: count
      end)

    if added > 0, do: persist()
    :ok
  end

  @spec reset() :: :ok
  def reset do
    case :ets.info(@ets) do
      :undefined ->
        :ok

      _other ->
        :ets.delete_all_objects(@ets)
        :ok
    end
  end

  @spec ensure_loaded() :: :ok
  defp ensure_loaded do
    Longbridge.Symbol.Store.ensure_cache()
  end

  @doc false
  # The ETS table name. Exposed so tests can inspect ownership without
  # hardcoding the internal atom.
  @spec table() :: atom()
  def table, do: @ets

  @doc false
  # Creates the cache ETS table and loads it from disk. The table is
  # registered to the calling process, so this is invoked by
  # `Longbridge.Symbol.Store` (a long-lived GenServer) to keep the table
  # alive across arbitrary caller death. Never raises: a missing cache
  # file is a normal cold-start condition.
  @spec create_and_load() :: :ok
  def create_and_load do
    _ = :ets.new(@ets, [:set, :named_table, :public, read_concurrency: true])
    load_from_disk()
    :ok
  end

  @doc false
  # Drops the cache ETS table so the next lookup reloads from disk.
  # Safe to call when the table is already gone.
  @spec drop() :: :ok
  def drop do
    try do
      :ets.delete(@ets)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp load_from_disk do
    path = cache_file_path()

    case File.read(path) do
      {:ok, content} ->
        Enum.each(String.split(content, "\n", trim: true), fn line ->
          if line != "", do: :ets.insert(@ets, {line})
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("longbridge counter-id cache read failed: #{inspect(reason)}")
        :ok
    end
  end

  defp persist do
    path = cache_file_path()
    File.mkdir_p!(Path.dirname(path))

    contents =
      @ets
      |> :ets.tab2list()
      |> Enum.map(fn {cid} -> cid end)
      |> Enum.sort()
      |> Enum.join("\n")

    File.write!(path, contents <> "\n")
  end

  defp cache_file_path do
    dir =
      System.get_env(@cache_path_env) ||
        Path.join([System.user_home!(), ".longbridge", "cache"])

    Path.join(dir, "counter-ids.csv")
  end
end
