defmodule Longbridge.Symbol do
  @moduledoc """
  Symbol ↔ counter_id conversion utilities.

  Longbridge's HTTP endpoints address instruments by an internal
  `counter_id` (e.g. `ST/US/AAPL`, `ST/HK/700`, `ETF/US/SPY`, `IX/HK/HSI`),
  not by the user-facing symbol (`AAPL.US`, `700.HK`, ...). The WebSocket
  layer accepts user symbols and normalises them on the server, but the
  HTTP `MarketContext` endpoints (broker-holding, ahpremium, ...) require
  the converted form.

  ## Local conversion (offline)

  `to_counter_id/1` and friends mirror `symbol_to_counter_id/1` from
  `longbridge/openapi/rust/src/utils/counter.rs` exactly:

    * Leading-dot symbols (e.g. `.DJI.US`) are US-style indexes and
      always map to the `IX/` prefix.
    * HK numeric codes have leading zeros stripped
      (`00700.HK` → `ST/HK/700`).
    * SZ/CN codes keep leading zeros (`000001.SZ` → `ST/SZ/000001`).
    * ETFs / warrants / non-stock indexes are matched against the embedded
      directory first.
    * Everything else falls back to `ST/{MARKET}/{CODE}`.

  Embedded directory entries live in `priv/counter_ids/`. New listings
  resolved at runtime can be added to `Longbridge.Symbol.Cache` (loaded
  from `$LONGBRIDGE_CACHE_DIR/counter-ids.csv` when present).

  ## Remote batch lookup (online)

  For symbols missing from the embedded directory (e.g. newly listed
  ETFs), `resolve_counter_ids/2` calls `POST /v1/quote/symbol-to-counter-ids`
  with the unresolved symbols and merges the server's resolution back
  into the result. Resolved entries are added to the local cache so
  subsequent lookups don't need a network round-trip.

  Mirrors `QuoteContext::symbol_to_counter_ids` and
  `QuoteContext::resolve_counter_ids` in `longbridge/openapi` Rust SDK
  (added in 4.3.0).
  """

  alias Longbridge.{Config, HTTPClient}
  alias Longbridge.Symbol.{Cache, Directory}

  @remote_batch_path "/v1/quote/symbol-to-counter-ids"

  @doc """
  Resolves a list of symbols to their `counter_id`s.

  Uses the embedded directory first, then the remote API at
  `POST /v1/quote/symbol-to-counter-ids` for any unknown symbols.
  Resolved entries are added to the local cache so subsequent
  lookups don't repeat the network call.

  Returns `{:ok, [%{symbol: String.t(), counter_id: String.t()}]}`
  with one entry per input symbol, in the same order. Symbols the
  backend does not recognize fall back to the local default
  `ST/{MARKET}/{CODE}` conversion.
  """
  @spec resolve_counter_ids(Config.t(), [String.t()]) ::
          {:ok, [%{String.t() => String.t()}]}
  def resolve_counter_ids(%Config{} = config, symbols) when is_list(symbols) do
    {local, unknown} = split_known_unknown(symbols)

    remote_map =
      case unknown do
        [] ->
          %{}

        _ ->
          case remote_lookup(config, unknown) do
            {:ok, list} when is_map(list) -> list
            _ -> %{}
          end
      end

    Cache.put(Map.values(remote_map))

    result =
      Enum.map(symbols, fn symbol ->
        cid =
          cond do
            cid = Map.get(local, symbol) -> cid
            cid = Map.get(remote_map, symbol) -> cid
            true -> to_counter_id(symbol)
          end

        %{symbol: symbol, counter_id: cid}
      end)

    {:ok, result}
  end

  # Split into symbols whose embedded-directory lookup gives a specific
  # counter_id (local) and symbols whose lookup falls through to the
  # generic ST/{MARKET}/{CODE} default (which we treat as unknown and
  # send to the server for a possibly-different resolution).
  defp split_known_unknown(symbols) do
    Enum.reduce(symbols, {%{}, []}, fn symbol, {local_acc, unknown_acc} ->
      case rsplit_dot(symbol) do
        {code, market} when is_binary(code) and is_binary(market) ->
          market = String.upcase(market)

          case Cache.lookup(symbol) || Directory.lookup(symbol, market, code) do
            cid when is_binary(cid) -> {Map.put(local_acc, symbol, cid), unknown_acc}
            nil -> {local_acc, [symbol | unknown_acc]}
          end

        :no_dot ->
          # No market suffix — can't dispatch to the server.
          {local_acc, [symbol | unknown_acc]}
      end
    end)
  end

  defp remote_lookup(%Config{} = config, symbols) do
    body = Jason.encode!(%{ticker_regions: symbols})

    case HTTPClient.request_json(:post, @remote_batch_path, body, config) do
      {:ok, %{"list" => list}} when is_map(list) -> {:ok, list}
      {:ok, _} -> {:ok, %{}}
      error -> error
    end
  end

  @doc """
  Convert a user-supplied symbol to its internal `counter_id`.
  """
  @spec to_counter_id(String.t()) :: String.t()
  def to_counter_id(symbol) when is_binary(symbol) do
    case rsplit_dot(symbol) do
      {code, market} when is_binary(code) and is_binary(market) ->
        market = String.upcase(market)
        code = strip_hk_leading_zero(code, market)

        case Cache.lookup(symbol) || Directory.lookup(symbol, market, code) do
          nil -> "ST/#{market}/#{code}"
          cid -> cid
        end

      :no_dot ->
        symbol
    end
  end

  def to_counter_id(symbol), do: symbol

  @doc """
  Convert a user-supplied index symbol (`HSI.HK`, `.DJI.US`) to its
  counter_id, always using the `IX/` prefix.
  """
  @spec index_to_counter_id(String.t()) :: String.t()
  def index_to_counter_id(symbol) when is_binary(symbol) do
    case rsplit_dot(symbol) do
      {code, market} -> "IX/#{String.upcase(market)}/#{code}"
      :no_dot -> symbol
    end
  end

  @doc """
  Convert a counter_id (e.g. `ST/US/AAPL`, `IX/HK/HSI`) back to its
  user-facing display symbol.
  """
  @spec from_counter_id(String.t()) :: String.t()
  def from_counter_id(counter_id) when is_binary(counter_id) do
    case String.split(counter_id, "/", parts: 3) do
      [_prefix, market, code] -> "#{code}.#{market}"
      _other -> counter_id
    end
  end

  # Strip the prefix dot for index symbols (`.DJI` → `.DJI`).
  # `00700.HK` → `700`. Other markets (incl. SZ/CN) keep their codes verbatim.
  defp strip_hk_leading_zero(code, "HK") do
    if String.match?(code, ~r/^\d+$/) do
      String.replace_leading(code, "0", "")
    else
      code
    end
  end

  defp strip_hk_leading_zero(code, _market), do: code

  # Splits `".DJI.US"` → `{".DJI", "US"}`, `"AAPL.US"` → `{"AAPL", "US"}`,
  # `"NODOT"` → `:no_dot`. Mirrors Rust's `split_once('.')` semantics by
  # splitting at the **last** dot only.
  defp rsplit_dot(symbol) do
    case :binary.matches(symbol, ".") do
      [] ->
        :no_dot

      matches ->
        {pos, _len} = List.last(matches)
        <<code::binary-size(^pos), ?., market::binary>> = symbol
        {code, market}
    end
  end
end
