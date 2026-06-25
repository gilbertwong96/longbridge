defmodule Longbridge.Symbol do
  @moduledoc """
  Symbol ↔ counter_id conversion utilities.

  Longbridge's HTTP endpoints address instruments by an internal
  `counter_id` (e.g. `ST/US/AAPL`, `ST/HK/700`, `ETF/US/SPY`, `IX/HK/HSI`),
  not by the user-facing symbol (`AAPL.US`, `700.HK`, ...). The WebSocket
  layer accepts user symbols and normalises them on the server, but the
  HTTP `MarketContext` endpoints (broker-holding, ahpremium, ...) require
  the converted form.

  This module mirrors `symbol_to_counter_id/1` from
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
  """

  alias Longbridge.Symbol.{Cache, Directory}

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
